#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'build.sh must run as root' >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${1:-$script_dir/out}"
source_archive="$script_dir/source/t3mp3st-source.tar.gz"
source_checksum="$script_dir/source/t3mp3st-source.tar.gz.sha256"

base_name=debian-13-standard_13.6-1_amd64.tar.zst
base_url="http://download.proxmox.com/images/system/$base_name"
base_sha512=4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b
node_version=22.19.0
node_sha256=c0649af18e6a24f6fe5535a3e86b341dd49a8e71117c8b68bde973ef834f16f2
image_name=t3mp3st-gpt-oss-120b-debian13.6-pve-amd64-20260811.tar.zst
source_date_epoch=1786406400

work_dir="$(mktemp -d -t t3mp3st-trixie.XXXXXXXX)"
rootfs="$work_dir/rootfs"
downloads="$work_dir/downloads"
mounts_active=0
cleanup() {
  if (( mounts_active )); then
    mountpoint -q "$rootfs/dev" && umount -l "$rootfs/dev" || true
    mountpoint -q "$rootfs/sys" && umount -l "$rootfs/sys" || true
    mountpoint -q "$rootfs/proc" && umount -l "$rootfs/proc" || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
mkdir -p "$rootfs" "$downloads" "$out_dir"

echo '[1/9] Runner dependencies and verified official Proxmox Debian 13.6 rootfs'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq unzip xz-utils zstd
curl --fail --location --proto '=http' "$base_url" -o "$downloads/$base_name"
printf '%s  %s\n' "$base_sha512" "$downloads/$base_name" | sha512sum --check --strict
tar --use-compress-program=unzstd -xf "$downloads/$base_name" -C "$rootfs"

echo '[2/9] Chroot and OS packages'
cp -a "$rootfs/etc/resolv.conf" "$work_dir/resolv.conf.original" 2>/dev/null || true
rm -f "$rootfs/etc/resolv.conf"
cp --dereference /etc/resolv.conf "$rootfs/etc/resolv.conf"
cat > "$rootfs/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$rootfs/usr/sbin/policy-rc.d"
mount -t proc proc "$rootfs/proc"
mount --rbind /sys "$rootfs/sys"; mount --make-rslave "$rootfs/sys"
mount --rbind /dev "$rootfs/dev"; mount --make-rslave "$rootfs/dev"
mounts_active=1
chroot "$rootfs" apt-get update
chroot "$rootfs" apt-get install -y --no-install-recommends \
  systemd-sysv dbus openssh-server sudo nginx apache2-utils ca-certificates curl wget git \
  build-essential make gcc g++ python3 python3-venv python3-pip pipx \
  jq file openssl dnsutils whois nmap iproute2 iputils-ping netcat-openbsd lsof tcpdump \
  procps less vim-tiny ripgrep unzip xz-utils zstd tar locales ifupdown \
  chromium pandoc poppler-utils weasyprint libimage-exiftool-perl yara \
  perl libnet-ssleay-perl libjson-perl libio-socket-ssl-perl libxml-writer-perl libxml-libxml-perl \
  sqlmap whatweb testssl.sh
chroot "$rootfs" apt-get clean
rm -rf "$rootfs/var/lib/apt/lists"/*
printf 'en_US.UTF-8 UTF-8\n' > "$rootfs/etc/locale.gen"
chroot "$rootfs" locale-gen en_US.UTF-8

echo '[3/9] Pinned Node.js and checksummed T3MP3ST source snapshot'
node_archive="node-v${node_version}-linux-x64.tar.xz"
curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v${node_version}/${node_archive}" -o "$downloads/$node_archive"
printf '%s  %s\n' "$node_sha256" "$downloads/$node_archive" | sha256sum --check --strict
tar -xJf "$downloads/$node_archive" -C "$rootfs/opt"
for binary in node npm npx corepack; do ln -sfn "/opt/node-v${node_version}-linux-x64/bin/$binary" "$rootfs/usr/local/bin/$binary"; done
[[ -f "$source_archive" && -f "$source_checksum" ]] || { echo 'Missing source archive/checksum.' >&2; exit 3; }
(cd "$(dirname "$source_archive")" && sha256sum -c "$(basename "$source_checksum")")
mkdir -p "$rootfs/opt/t3mp3st"
tar -xzf "$source_archive" -C "$rootfs/opt/t3mp3st"

echo '[4/9] Application install and source acceptance gates'
chroot "$rootfs" useradd --system --create-home --home-dir /var/lib/t3mp3st/home --shell /bin/bash t3mp3st
chroot "$rootfs" useradd --create-home --shell /bin/bash t3admin
chroot "$rootfs" passwd --lock t3admin
t3_uid="$(chroot "$rootfs" id -u t3mp3st)"; t3_gid="$(chroot "$rootfs" id -g t3mp3st)"
install -d -m 0750 -o "$t3_uid" -g "$t3_gid" "$rootfs/var/lib/t3mp3st" "$rootfs/var/lib/t3mp3st/home" "$rootfs/var/lib/t3mp3st/reports" "$rootfs/var/lib/t3mp3st/evidence" "$rootfs/var/lib/t3mp3st/state"
chown -R "$t3_uid:$t3_gid" "$rootfs/opt/t3mp3st"
run_as_t3mp3st() {
  chroot "$rootfs" runuser -u t3mp3st -- env \
    HOME=/var/lib/t3mp3st/home \
    XDG_CONFIG_HOME=/var/lib/t3mp3st/home/.config \
    XDG_CACHE_HOME=/var/lib/t3mp3st/home/.cache \
    PATH=/usr/local/bin:/usr/bin:/bin \
    "$@"
}
run_as_t3mp3st env NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false npm --prefix /opt/t3mp3st ci
run_as_t3mp3st npm --prefix /opt/t3mp3st run typecheck
run_as_t3mp3st npm --prefix /opt/t3mp3st run lint
run_as_t3mp3st npm --prefix /opt/t3mp3st test -- --run
run_as_t3mp3st npm --prefix /opt/t3mp3st run build
run_as_t3mp3st node /opt/t3mp3st/scripts/evidence-persistence-e2e.mjs
chown -R root:root "$rootfs/opt/t3mp3st"
ln -sfn /var/lib/t3mp3st/reports "$rootfs/opt/t3mp3st/reports"
ln -sfn /var/lib/t3mp3st/evidence "$rootfs/opt/t3mp3st/evidence"

echo '[5/9] Checksummed security toolchain'
install_locked_tool() {
  local name=$1 version=$2 url=$3 sha=$4 format=$5 selector=$6 archive="$downloads/${name}-${version}"
  curl --fail --location --proto '=https' --tlsv1.2 "$url" -o "$archive"
  printf '%s  %s\n' "$sha" "$archive" | sha256sum --check --strict
  local extract="$downloads/extract-$name" source
  mkdir -p "$extract"
  case "$format" in
    zip) unzip -q "$archive" -d "$extract" ;;
    tar.gz) tar -xzf "$archive" -C "$extract" ;;
    raw) cp "$archive" "$extract/$selector" ;;
    *) echo "Unsupported format: $format" >&2; return 1 ;;
  esac
  source="$(find "$extract" -type f -name "$selector" -print -quit)"
  [[ -n "$source" ]] || { echo "$name binary missing in archive" >&2; return 1; }
  if [[ "$name" == nikto ]]; then
    rm -rf "$rootfs/opt/nikto"
    cp -a "$(dirname "$(dirname "$source")")" "$rootfs/opt/nikto"
    chmod 0755 "$rootfs/opt/nikto/program/nikto.pl"
    ln -sfn /opt/nikto/program/nikto.pl "$rootfs/usr/local/bin/nikto"
    return
  fi
  install -m 0755 "$source" "$rootfs/usr/local/bin/$selector"
}
while IFS=$'\t' read -r name version url sha format selector; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  install_locked_tool "$name" "$version" "$url" "$sha" "$format" "$selector"
done < "$script_dir/tools.lock.tsv"
chroot "$rootfs" python3 -m venv /opt/semgrep
chroot "$rootfs" /opt/semgrep/bin/pip install --no-cache-dir 'semgrep==1.131.0'
ln -sfn /opt/semgrep/bin/semgrep "$rootfs/usr/local/bin/semgrep"
chroot "$rootfs" python3 -m venv /opt/wafw00f
chroot "$rootfs" /opt/wafw00f/bin/pip install --no-cache-dir 'wafw00f==2.3.2'
ln -sfn /opt/wafw00f/bin/wafw00f "$rootfs/usr/local/bin/wafw00f"

echo '[6/9] Runtime services, nginx, first boot and secure configuration'
install -d -m 0751 -o root -g "$t3_gid" "$rootfs/etc/t3mp3st"
install -d -m 0755 "$rootfs/usr/local/lib/t3mp3st" "$rootfs/usr/local/share/t3mp3st" "$rootfs/etc/ssh/sshd_config.d"
install -m 0640 -o root -g "$t3_gid" "$script_dir/t3mp3st.env" "$rootfs/etc/t3mp3st/t3mp3st.env"
install -m 0640 -o root -g "$t3_gid" "$script_dir/relay.env.example" "$rootfs/etc/t3mp3st/relay.env"
install -m 0644 "$script_dir/t3mp3st.service" "$script_dir/t3mp3st-llm-relay.service" "$script_dir/t3mp3st-firstboot.service" "$rootfs/etc/systemd/system/"
install -m 0644 "$script_dir/gpt-oss-relay.mjs" "$rootfs/usr/local/lib/t3mp3st/gpt-oss-relay.mjs"
install -m 0755 "$script_dir/t3mp3st-firstboot.sh" "$rootfs/usr/local/sbin/t3mp3st-firstboot"
install -m 0755 "$script_dir/configure-gpt-oss.sh" "$rootfs/usr/local/sbin/configure-gpt-oss"
install -m 0755 "$script_dir/t3mp3st-verify.sh" "$rootfs/usr/local/sbin/t3mp3st-verify"
install -m 0644 "$script_dir/required-tools.json" "$rootfs/usr/local/share/t3mp3st/required-tools.json"
install -m 0644 "$script_dir/tools.lock.tsv" "$rootfs/usr/local/share/t3mp3st/tools.lock.tsv"
install -m 0644 "$script_dir/sshd-t3mp3st.conf" "$rootfs/etc/ssh/sshd_config.d/99-t3mp3st.conf"
rm -f "$rootfs/etc/nginx/sites-enabled/default"
install -m 0644 "$script_dir/nginx-t3mp3st.conf" "$rootfs/etc/nginx/conf.d/t3mp3st.conf"
install -d -m 0750 "$rootfs/etc/t3mp3st/tls"
chroot "$rootfs" openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=build-only \
  -keyout /etc/t3mp3st/tls/server.key -out /etc/t3mp3st/tls/server.crt >/dev/null 2>&1
printf 'build-only\n' | chroot "$rootfs" htpasswd -i -cB /etc/t3mp3st/nginx.htpasswd t3admin >/dev/null
cat > "$rootfs/etc/sudoers.d/90-t3admin" <<'EOF'
t3admin ALL=(root) NOPASSWD: /usr/local/sbin/configure-gpt-oss, /usr/local/sbin/configure-gpt-oss --key-file *, /usr/local/sbin/t3mp3st-verify, /usr/local/sbin/t3mp3st-verify *, /usr/bin/systemctl restart t3mp3st.service, /usr/bin/systemctl restart t3mp3st-llm-relay.service, /usr/bin/systemctl restart nginx.service, /usr/bin/journalctl -u t3mp3st.service *, /usr/bin/htpasswd /etc/t3mp3st/nginx.htpasswd t3admin
EOF
chmod 0440 "$rootfs/etc/sudoers.d/90-t3admin"
for unit in t3mp3st-firstboot.service t3mp3st-llm-relay.service t3mp3st.service nginx.service ssh.service; do chroot "$rootfs" systemctl enable "$unit"; done

echo '[7/9] Static image acceptance and secret guard'
chroot "$rootfs" node --version | grep -Fx "v$node_version"
chroot "$rootfs" node --check /opt/t3mp3st/dist/server.js
chroot "$rootfs" node --check /usr/local/lib/t3mp3st/gpt-oss-relay.mjs
chroot "$rootfs" nginx -t
while IFS= read -r tool; do chroot "$rootfs" sh -c "command -v '$tool' >/dev/null"; done < <(jq -r '.required[]' "$script_dir/required-tools.json")
secret_failure=0
while IFS= read -r secret_file; do
  if grep -E '(OPENAI_API_KEY|GPT_OSS_API_KEY)=[A-Za-z0-9_./+=-]{12,}' "$secret_file" | grep -Fv 'OPENAI_API_KEY=relay-managed-local-only' >/dev/null; then
    echo "Possible embedded API key found in: ${secret_file#$rootfs}" >&2
    secret_failure=1
  fi
done < <(grep -RIlE --exclude='*.test.ts' --exclude='*.md' --exclude='*.env.example' --exclude='relay.env' '(OPENAI_API_KEY|GPT_OSS_API_KEY)=[A-Za-z0-9_./+=-]{12,}' "$rootfs/etc/t3mp3st" "$rootfs/opt/t3mp3st" || true)
(( secret_failure == 0 )) || exit 5

echo '[8/9] Template hygiene and deterministic package'
rm -f "$rootfs/etc/machine-id"; : > "$rootfs/etc/machine-id"
rm -f "$rootfs/etc/t3mp3st/nginx.htpasswd" "$rootfs/etc/t3mp3st/tls/server.key" "$rootfs/etc/t3mp3st/tls/server.crt"
rm -f "$rootfs/var/lib/dbus/machine-id" "$rootfs/etc/ssh/ssh_host_"*
rm -f "$rootfs/usr/sbin/policy-rc.d"
rm -f "$rootfs/etc/resolv.conf"
if [[ -e "$work_dir/resolv.conf.original" ]]; then cp -a "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"; else : > "$rootfs/etc/resolv.conf"; fi
find "$rootfs/var/log" -type f -exec truncate -s 0 {} +
rm -rf "$rootfs/tmp"/* "$rootfs/var/tmp"/* "$rootfs/root/.cache"
mountpoint -q "$rootfs/dev" && umount -l "$rootfs/dev"
mountpoint -q "$rootfs/sys" && umount -l "$rootfs/sys"
mountpoint -q "$rootfs/proc" && umount -l "$rootfs/proc"
mounts_active=0
tar --sort=name --mtime="@$source_date_epoch" --clamp-mtime --numeric-owner \
  --pax-option=delete=atime,delete=ctime -C "$rootfs" -cf - . | zstd -19 -T0 -o "$out_dir/$image_name"

echo '[9/9] Release evidence and checksums'
source_sha="$(cut -d' ' -f1 "$source_checksum")"
image_sha="$(sha256sum "$out_dir/$image_name" | cut -d' ' -f1)"
hotfix_name=t3mp3st-evidence-hotfix-debian13-amd64.tar.gz
tar --sort=name --mtime="@$source_date_epoch" --clamp-mtime --numeric-owner \
  --pax-option=delete=atime,delete=ctime -C "$rootfs/opt/t3mp3st" -cf - dist docs \
  | gzip -n -9 > "$out_dir/$hotfix_name"
cat > "$out_dir/BUILD-MANIFEST.json" <<EOF
{"schema":1,"image":"$image_name","sha256":"$image_sha","hotfix":"$hotfix_name","base":"$base_name","base_sha512":"$base_sha512","source_sha256":"$source_sha","node":"$node_version","model":"gpt-oss-120b","os":"Debian 13.6","build_epoch":$source_date_epoch}
EOF
cp "$script_dir/README_RU.md" "$script_dir/deploy-from-ct101.sh" "$script_dir/upgrade-evidence-hotfix.sh" \
  "$script_dir/t3mp3st-verify.sh" "$script_dir/required-tools.json" "$script_dir/tools.lock.tsv" "$out_dir/"
(cd "$out_dir" && sha256sum "$image_name" "$hotfix_name" BUILD-MANIFEST.json \
  deploy-from-ct101.sh upgrade-evidence-hotfix.sh t3mp3st-verify.sh > SHA256SUMS)
echo "Built: $out_dir/$image_name"
