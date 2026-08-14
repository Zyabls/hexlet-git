#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Run on a Proxmox VE node as root:
  deploy-deepeye.sh IMAGE.tar.zst CTID --ip CIDR --gateway IP [options]

Required:
  --ip CIDR                 A NEW, unused address, for example 192.168.1.242/24
  --gateway IP              Gateway for the container network

Options:
  --bridge NAME             Default: vmbr0
  --storage NAME            Root disk storage, default: local-lvm
  --template-storage NAME   Template storage, default: local
  --hostname NAME           Default: deepeye-gptoss
  --dns IP                  Proxmox nameserver setting
  --search DOMAIN           Proxmox search domain setting
  --ssh-key FILE            Public key installed for root/deepadmin
  --web-password-file FILE  Root-readable file, at least 12 characters
  --llm-key-file FILE       Root-readable gpt-oss API key file
  --llm-upstream URL        Default: https://llm.enplus.group/v1
  --llm-tls MODE            strict, custom-ca or insecure-host
  --llm-ca FILE             CA certificate when MODE=custom-ca

The script refuses an existing CTID and never copies the old T3MP3ST data or
credentials. Reusing an address that is still assigned to another guest will
cause a network conflict.
EOF
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run on PVE as root.' >&2; exit 1; }
command -v pct >/dev/null || { echo 'pct not found: run this on a Proxmox VE node.' >&2; exit 2; }
[[ $# -ge 2 ]] || { usage >&2; exit 2; }

image="$(readlink -f -- "$1")"
ctid=$2
shift 2
ip_cidr=''; gateway=''; bridge=vmbr0; storage=local-lvm; template_storage=local
hostname=deepeye-gptoss; dns=''; search=''; ssh_key=''; web_password_file=''; llm_key_file=''
llm_upstream=https://llm.enplus.group/v1; llm_tls=strict; llm_ca=''
while (($#)); do
  case "$1" in
    --ip) ip_cidr=${2:-}; shift 2 ;;
    --gateway) gateway=${2:-}; shift 2 ;;
    --bridge) bridge=${2:-}; shift 2 ;;
    --storage) storage=${2:-}; shift 2 ;;
    --template-storage) template_storage=${2:-}; shift 2 ;;
    --hostname) hostname=${2:-}; shift 2 ;;
    --dns) dns=${2:-}; shift 2 ;;
    --search) search=${2:-}; shift 2 ;;
    --ssh-key) ssh_key=${2:-}; shift 2 ;;
    --web-password-file) web_password_file=${2:-}; shift 2 ;;
    --llm-key-file) llm_key_file=${2:-}; shift 2 ;;
    --llm-upstream) llm_upstream=${2:-}; shift 2 ;;
    --llm-tls) llm_tls=${2:-}; shift 2 ;;
    --llm-ca) llm_ca=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$image" ]] || { echo 'Image file not found.' >&2; exit 2; }
[[ "$ctid" =~ ^[1-9][0-9]{2,8}$ ]] || { echo 'Invalid CTID.' >&2; exit 2; }
[[ "$ip_cidr" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || { echo 'A valid --ip CIDR is required.' >&2; exit 2; }
[[ -n "$gateway" && "$gateway" != *[[:space:]]* ]] || { echo 'A valid --gateway is required.' >&2; exit 2; }
[[ "$bridge" =~ ^[A-Za-z0-9_.:-]+$ && "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || { echo 'Invalid bridge or hostname.' >&2; exit 2; }
[[ "$llm_tls" =~ ^(strict|custom-ca|insecure-host)$ ]] || { echo 'Invalid --llm-tls.' >&2; exit 2; }
for candidate in "$ssh_key" "$web_password_file" "$llm_key_file" "$llm_ca"; do
  [[ -z "$candidate" || -f "$candidate" ]] || { echo "Input file not found: $candidate" >&2; exit 2; }
done
[[ "$llm_tls" != custom-ca || -n "$llm_ca" ]] || { echo '--llm-ca is required for custom-ca.' >&2; exit 2; }
if pct status "$ctid" >/dev/null 2>&1; then echo "CT $ctid already exists; refusing to overwrite it." >&2; exit 3; fi
pvesm status --storage "$storage" >/dev/null
pvesm status --storage "$template_storage" >/dev/null
ip -o link show "$bridge" >/dev/null || { echo "Bridge $bridge does not exist." >&2; exit 3; }

template_volume="${template_storage}:vztmpl/$(basename "$image")"
template_path="$(pvesm path "$template_volume")"
install -d -m 0755 "$(dirname "$template_path")"
if [[ -f "$template_path" ]] && ! cmp -s "$image" "$template_path"; then
  echo "A different template already exists at $template_path; refusing to overwrite." >&2
  exit 3
fi
[[ -f "$template_path" ]] || install -m 0644 "$image" "$template_path"

net0="name=eth0,bridge=${bridge},ip=${ip_cidr},gw=${gateway},firewall=1,type=veth"
create_args=("$ctid" "$template_volume" --hostname "$hostname" --unprivileged 1
  --cores 4 --memory 8192 --swap 2048 --rootfs "${storage}:100"
  --net0 "$net0" --features keyctl=1 --onboot 1 --startup order=30)
[[ -z "$ssh_key" ]] || create_args+=(--ssh-public-keys "$ssh_key")

echo "Creating unprivileged CT $ctid on $storage with $ip_cidr."
pct create "${create_args[@]}"
[[ -z "$dns" ]] || pct set "$ctid" --nameserver "$dns"
[[ -z "$search" ]] || pct set "$ctid" --searchdomain "$search"

rollback() {
  echo "Deployment failed. CT $ctid is retained for inspection and is not deleted automatically." >&2
}
trap rollback ERR
pct start "$ctid"
for _ in $(seq 1 60); do
  pct exec "$ctid" -- systemctl is-system-running --wait >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$ctid" -- systemctl start deepeye-firstboot.service

if [[ -n "$web_password_file" ]]; then
  pct push "$ctid" "$web_password_file" /root/.deepeye-web-password --perms 0600
  pct exec "$ctid" -- /usr/local/sbin/deepeye-set-password /root/.deepeye-web-password
  pct exec "$ctid" -- rm -f /root/.deepeye-web-password
fi
if [[ -n "$llm_ca" ]]; then
  pct push "$ctid" "$llm_ca" /etc/deepeye/corporate-ca.pem --perms 0644
fi
if [[ -n "$llm_key_file" ]]; then
  pct push "$ctid" "$llm_key_file" /root/.deepeye-llm-key --perms 0600
  llm_args=(/usr/local/sbin/configure-deepeye-llm --key-file /root/.deepeye-llm-key --upstream "$llm_upstream" --tls-mode "$llm_tls")
  [[ -z "$llm_ca" ]] || llm_args+=(--ca-file /etc/deepeye/corporate-ca.pem)
  pct exec "$ctid" -- "${llm_args[@]}"
  pct exec "$ctid" -- rm -f /root/.deepeye-llm-key
fi

pct exec "$ctid" -- nginx -t
pct exec "$ctid" -- /usr/local/sbin/deepeye-verify
trap - ERR
echo "CT $ctid is ready: https://${ip_cidr%/*}/"
if [[ -z "$web_password_file" ]]; then
  echo "Initial random credentials: pct exec $ctid -- cat /root/deepeye-initial-credentials.txt"
else
  echo 'Web user: deepadmin (password was read from your file).'
fi
if [[ -z "$llm_key_file" ]]; then
  echo "Configure LLM later: pct push $ctid KEYFILE /root/key && pct exec $ctid -- configure-deepeye-llm --key-file /root/key"
fi
