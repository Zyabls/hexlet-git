#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Run on a Proxmox VE node:
  deploy-from-ct101.sh IMAGE.tar.zst NEW_CTID [--cutover]

Creates an unprivileged 4 CPU/8 GiB/100 GiB CT, copies CT 101 network/DNS
settings without its MAC address, and securely migrates existing GPT relay,
corporate CA, nginx password file and SSH key. Without --cutover the new CT is
started with its NIC disconnected, so it cannot conflict with CT 101.
EOF
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run on PVE as root.' >&2; exit 1; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
command -v pct >/dev/null || { echo 'pct not found: this script must run on PVE.' >&2; exit 2; }

image="$(readlink -f -- "$1")"
new_id=$2
cutover=0
[[ ${3:-} == --cutover ]] && cutover=1
old_id="${SOURCE_CTID:-101}"
storage="${PVE_STORAGE:-local-lvm}"
template_storage="${PVE_TEMPLATE_STORAGE:-local}"
hostname="${NEW_HOSTNAME:-t3mp3st-gptoss}"

[[ -f "$image" && "$new_id" =~ ^[1-9][0-9]{2,8}$ ]] || { echo 'Invalid image path or CTID.' >&2; exit 2; }
pvesm status --storage "$template_storage" >/dev/null
template_volume="${template_storage}:vztmpl/$(basename "$image")"
template_path="$(pvesm path "$template_volume")"
if [[ "$image" != "$template_path" ]]; then
  install -d -m 0755 "$(dirname "$template_path")"
  if [[ -f "$template_path" ]] && ! cmp -s "$image" "$template_path"; then
    echo "Different template already exists at $template_path; refusing to overwrite." >&2
    exit 3
  fi
  [[ -f "$template_path" ]] || install -m 0644 "$image" "$template_path"
fi
pct status "$old_id" >/dev/null
if pct status "$new_id" >/dev/null 2>&1; then echo "CT $new_id already exists; refusing to overwrite." >&2; exit 3; fi

old_config="$(pct config "$old_id")"
net0="$(sed -n 's/^net0: //p' <<<"$old_config")"
[[ -n "$net0" ]] || { echo "CT $old_id has no net0." >&2; exit 3; }
filtered=()
IFS=',' read -ra fields <<< "$net0"
for field in "${fields[@]}"; do
  [[ "$field" == hwaddr=* || "$field" == link_down=* ]] || filtered+=("$field")
done
net0="$(IFS=,; printf '%s' "${filtered[*]}")"
net0_disconnected="${net0},link_down=1"
nameserver="$(sed -n 's/^nameserver: //p' <<<"$old_config")"
searchdomain="$(sed -n 's/^searchdomain: //p' <<<"$old_config")"

echo "Creating CT $new_id from verified image; network remains disconnected."
pct create "$new_id" "$template_volume" --hostname "$hostname" --unprivileged 1 \
  --cores 4 --memory 8192 --swap 2048 --rootfs "${storage}:100" \
  --net0 "$net0_disconnected" --features keyctl=1 --onboot 1 --startup order=30
[[ -z "$nameserver" ]] || pct set "$new_id" --nameserver "$nameserver"
[[ -z "$searchdomain" ]] || pct set "$new_id" --searchdomain "$searchdomain"

old_mounted=0
new_mounted=0
cleanup_mounts() {
  (( new_mounted == 0 )) || pct unmount "$new_id" >/dev/null 2>&1 || true
  (( old_mounted == 0 )) || pct unmount "$old_id" >/dev/null 2>&1 || true
}
trap cleanup_mounts EXIT
if pct status "$old_id" | grep -q 'status: running'; then
  [[ -d "/var/lib/lxc/$old_id/rootfs/etc" ]] || { echo 'Running source CT rootfs is not accessible.' >&2; exit 4; }
else
  pct mount "$old_id" >/dev/null; old_mounted=1
fi
pct mount "$new_id" >/dev/null; new_mounted=1
old_root="$(readlink -f "/var/lib/lxc/$old_id/rootfs")"
new_root="$(readlink -f "/var/lib/lxc/$new_id/rootfs")"
[[ "$old_root" == /var/lib/lxc/"$old_id"/rootfs && "$new_root" == /var/lib/lxc/"$new_id"/rootfs ]] || { echo 'Unexpected LXC mount paths.' >&2; exit 4; }

root_uid="$(stat -c %u "$new_root/etc")"
root_gid="$(stat -c %g "$new_root/etc")"
t3_gid="$(stat -c %g "$new_root/etc/t3mp3st/t3mp3st.env")"
install -d -m 0750 -o "$root_uid" -g "$t3_gid" "$new_root/etc/t3mp3st"
api_key=''
for candidate in relay.env openai-relay.env t3mp3st.env; do
  candidate_path="$old_root/etc/t3mp3st/$candidate"
  [[ -f "$candidate_path" ]] || continue
  api_key="$(sed -n -E 's/^(GPT_OSS_API_KEY|OPENAI_API_KEY)=//p' "$candidate_path" | head -n1)"
  [[ -z "$api_key" ]] || break
done
if [[ -n "$api_key" ]]; then
  install -m 0640 -o "$root_uid" -g "$t3_gid" /dev/null "$new_root/etc/t3mp3st/relay.env"
  {
    printf 'GPT_OSS_UPSTREAM=https://llm.enplus.group/v1\n'
    printf 'GPT_OSS_MODEL=gpt-oss-120b\n'
    printf 'GPT_OSS_API_KEY=%s\n' "$api_key"
    printf 'GPT_OSS_TLS_MODE=insecure-host\n'
    printf 'GPT_OSS_CA_FILE=/etc/t3mp3st/corporate-ca.pem\n'
  } > "$new_root/etc/t3mp3st/relay.env"
  chown "$root_uid:$t3_gid" "$new_root/etc/t3mp3st/relay.env"
  unset api_key
fi
for ca in corporate-ca.pem llm-ca.pem; do
  [[ ! -f "$old_root/etc/t3mp3st/$ca" ]] || install -m 0644 -o "$root_uid" -g "$root_gid" "$old_root/etc/t3mp3st/$ca" "$new_root/etc/t3mp3st/corporate-ca.pem"
done
[[ ! -f "$old_root/etc/t3mp3st/nginx.htpasswd" ]] || install -m 0640 -o "$root_uid" -g "$t3_gid" "$old_root/etc/t3mp3st/nginx.htpasswd" "$new_root/etc/t3mp3st/nginx.htpasswd"
if [[ -s "$old_root/root/.ssh/authorized_keys" ]]; then
  install -d -m 0700 -o "$root_uid" -g "$root_gid" "$new_root/root/.ssh"
  install -m 0600 -o "$root_uid" -g "$root_gid" "$old_root/root/.ssh/authorized_keys" "$new_root/root/.ssh/authorized_keys"
fi
cleanup_mounts
old_mounted=0; new_mounted=0
trap - EXIT

pct start "$new_id"
sleep 8
# A migrated htpasswd file may retain the t3mp3st group from the mounted
# unprivileged rootfs. nginx workers run as www-data and return HTTP 500 when
# auth_basic cannot read that file, so enforce the runtime ownership here.
pct exec "$new_id" -- chown root:www-data /etc/t3mp3st/nginx.htpasswd
pct exec "$new_id" -- chmod 0640 /etc/t3mp3st/nginx.htpasswd
pct exec "$new_id" -- nginx -t
pct exec "$new_id" -- systemctl restart nginx.service
pct exec "$new_id" -- systemctl is-active --quiet nginx t3mp3st t3mp3st-llm-relay
echo "CT $new_id passed disconnected service boot."

if (( cutover == 0 )); then
  echo "No cutover requested. CT $new_id NIC is disconnected; CT $old_id remains unchanged."
  echo "After maintenance approval: $0 '$image' '$new_id' --cutover cannot be rerun because CT exists."
  echo "Use: pct stop $old_id && pct set $new_id --net0 '$net0' && pct start $new_id"
  exit 0
fi

echo "Cutover: stopping CT $old_id and attaching its exact network settings to CT $new_id."
pct stop "$new_id"
pct stop "$old_id"
rollback() {
  echo 'Cutover validation failed; rolling back to the source CT.' >&2
  pct stop "$new_id" >/dev/null 2>&1 || true
  pct start "$old_id" >/dev/null 2>&1 || true
}
trap rollback ERR
pct set "$new_id" --net0 "$net0"
pct start "$new_id"
sleep 12
pct exec "$new_id" -- /usr/local/sbin/t3mp3st-verify --live-llm --stability
trap - ERR
echo "Cutover complete. CT $old_id is stopped but retained for rollback; CT $new_id is verified."
