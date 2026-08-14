#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'build.sh must run as root' >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${1:-$script_dir/out}"

base_name=debian-13-standard_13.6-1_amd64.tar.zst
base_url="http://download.proxmox.com/images/system/$base_name"
base_sha512=4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b
source_commit=e98a361ee38ec65660ce585ff6789017a2d7a466
source_name="deep-eye-${source_commit}.tar.gz"
source_url="https://github.com/zakirkun/deep-eye/archive/${source_commit}.tar.gz"
source_sha512=030c12e99bd271513582d4739d1195fba662df48ef6c4474e0f92dd310fd228def997cbfdf89ae95a2b06e3f5e96477f0d1e225fd44572e77ef4ffc3e1df4eb5
node_version=22.19.0
node_sha256=c0649af18e6a24f6fe5535a3e86b341dd49a8e71117c8b68bde973ef834f16f2
image_name=deepeye-gpt-oss-120b-debian13.6-pve-amd64-20260814.tar.zst
source_date_epoch=1784990940

work_dir="$(mktemp -d -t deepeye-trixie.XXXXXXXX)"
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

echo '[1/9] Verified official Proxmox Debian 13.6 rootfs and pinned Deep Eye source'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq unzip xz-utils zstd
curl --fail --location --proto '=http' "$base_url" -o "$downloads/$base_name"
printf '%s  %s\n' "$base_sha512" "$downloads/$base_name" | sha512sum --check --strict
curl --fail --location --proto '=https' --tlsv1.2 "$source_url" -o "$downloads/$source_name"
printf '%s  %s\n' "$source_sha512" "$downloads/$source_name" | sha512sum --check --strict
tar --use-compress-program=unzstd -xf "$downloads/$base_name" -C "$rootfs"

echo '[2/9] Debian runtime and browser dependencies'
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
  systemd-sysv dbus openssh-server sudo nginx apache2-utils ca-certificates curl wget git patch \
  build-essential pkg-config python3 python3-dev python3-venv python3-pip \
  jq file openssl dnsutils whois nmap iproute2 iputils-ping netcat-openbsd lsof procps less vim-tiny ripgrep \
  unzip xz-utils zstd tar locales ifupdown chromium pandoc poppler-utils weasyprint \
  libmagic1 libxml2-dev libxslt1-dev libffi-dev libssl-dev
printf 'en_US.UTF-8 UTF-8\n' > "$rootfs/etc/locale.gen"
chroot "$rootfs" locale-gen en_US.UTF-8

echo '[3/9] Source patch, pinned Node relay and isolated Python environment'
mkdir -p "$rootfs/opt/deepeye"
tar -xzf "$downloads/$source_name" --strip-components=1 -C "$rootfs/opt/deepeye"
cp "$script_dir/openai-compatible.patch" "$rootfs/tmp/openai-compatible.patch"
chroot "$rootfs" bash -lc 'cd /opt/deepeye && patch -p1 --fuzz=0 < /tmp/openai-compatible.patch'
rm -f "$rootfs/tmp/openai-compatible.patch"

node_archive="node-v${node_version}-linux-x64.tar.xz"
curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v${node_version}/${node_archive}" -o "$downloads/$node_archive"
printf '%s  %s\n' "$node_sha256" "$downloads/$node_archive" | sha256sum --check --strict
tar -xJf "$downloads/$node_archive" -C "$rootfs/opt"
for binary in node npm npx corepack; do ln -sfn "/opt/node-v${node_version}-linux-x64/bin/$binary" "$rootfs/usr/local/bin/$binary"; done

chroot "$rootfs" useradd --system --create-home --home-dir /var/lib/deepeye/home --shell /bin/bash deepeye
chroot "$rootfs" useradd --create-home --shell /bin/bash deepadmin
chroot "$rootfs" passwd --lock deepadmin
deep_uid="$(chroot "$rootfs" id -u deepeye)"; deep_gid="$(chroot "$rootfs" id -g deepeye)"
install -d -m 0750 -o "$deep_uid" -g "$deep_gid" \
  "$rootfs/var/lib/deepeye" "$rootfs/var/lib/deepeye/home" "$rootfs/var/lib/deepeye/state" \
  "$rootfs/var/lib/deepeye/reports" "$rootfs/var/lib/deepeye/logs" "$rootfs/var/lib/deepeye/logs/jobs" "$rootfs/var/lib/deepeye/data"
chown -R "$deep_uid:$deep_gid" "$rootfs/opt/deepeye"
chroot "$rootfs" python3 -m venv /opt/deepeye/venv
chown -R "$deep_uid:$deep_gid" "$rootfs/opt/deepeye/venv"
run_as_deepeye() {
  chroot "$rootfs" runuser -u deepeye -- env \
    HOME=/var/lib/deepeye/home PATH=/opt/deepeye/venv/bin:/usr/local/bin:/usr/bin:/bin \
    PLAYWRIGHT_BROWSERS_PATH=/opt/deepeye/playwright "$@"
}
run_as_deepeye /opt/deepeye/venv/bin/pip install --no-cache-dir --upgrade 'pip==25.2' 'setuptools==80.9.0' 'wheel==0.45.1'
run_as_deepeye /opt/deepeye/venv/bin/pip install --no-cache-dir -r /opt/deepeye/requirements.txt \
  'openai==1.109.1' 'pytest==8.4.2' 'openpyxl==3.1.5'
run_as_deepeye /opt/deepeye/venv/bin/playwright install chromium
run_as_deepeye /opt/deepeye/venv/bin/pip freeze > "$rootfs/usr/local/share/deepeye-python-lock.txt"

echo '[4/9] Applicable upstream tests, compatibility regression and CLI smoke'
# The pinned upstream archive does not contain utils/compliance/frameworks/*.json,
# although test_compliance_mapping.py requires those files. Compliance is disabled
# in the supported profile; every other committed upstream test remains a gate.
run_as_deepeye bash -lc 'cd /opt/deepeye && pytest -q tests --ignore=tests/test_compliance_mapping.py'
run_as_deepeye /opt/deepeye/venv/bin/python /opt/deepeye/deep_eye.py --version
run_as_deepeye /opt/deepeye/venv/bin/python -m py_compile \
  /opt/deepeye/deep_eye.py /opt/deepeye/ai_providers/openai_provider.py
rm -rf "$rootfs/opt/deepeye/reports" "$rootfs/opt/deepeye/logs" "$rootfs/opt/deepeye/data"
ln -s /var/lib/deepeye/reports "$rootfs/opt/deepeye/reports"
ln -s /var/lib/deepeye/logs "$rootfs/opt/deepeye/logs"
ln -s /var/lib/deepeye/data "$rootfs/opt/deepeye/data"
chown -R root:root "$rootfs/opt/deepeye"
chown -R "$deep_uid:$deep_gid" "$rootfs/opt/deepeye/venv" "$rootfs/opt/deepeye/playwright"

echo '[5/9] Runtime services, nginx TLS/Auth and first boot'
install -d -m 0751 -o root -g "$deep_gid" "$rootfs/etc/deepeye"
install -d -m 0755 "$rootfs/usr/local/lib/deepeye" "$rootfs/etc/ssh/sshd_config.d"
install -m 0640 -o root -g "$deep_gid" "$script_dir/deepeye.env" "$rootfs/etc/deepeye/deepeye.env"
install -m 0640 -o root -g "$deep_gid" "$script_dir/deepeye-config.yaml" "$rootfs/etc/deepeye/config.yaml"
install -m 0640 -o root -g "$deep_gid" "$script_dir/relay.env.example" "$rootfs/etc/deepeye/relay.env"
install -m 0644 "$script_dir/deepeye.service" "$script_dir/deepeye-llm-relay.service" "$script_dir/deepeye-firstboot.service" "$rootfs/etc/systemd/system/"
install -m 0644 "$script_dir/gpt-oss-relay.mjs" "$rootfs/usr/local/lib/deepeye/gpt-oss-relay.mjs"
install -m 0755 "$script_dir/deepeye-web.py" "$rootfs/usr/local/lib/deepeye/deepeye-web.py"
install -m 0755 "$script_dir/deepeye-firstboot.sh" "$rootfs/usr/local/sbin/deepeye-firstboot"
install -m 0755 "$script_dir/configure-deepeye-llm.sh" "$rootfs/usr/local/sbin/configure-deepeye-llm"
install -m 0755 "$script_dir/deepeye-set-password.sh" "$rootfs/usr/local/sbin/deepeye-set-password"
install -m 0755 "$script_dir/deepeye-verify.sh" "$rootfs/usr/local/sbin/deepeye-verify"
install -m 0644 "$script_dir/sshd-deepeye.conf" "$rootfs/etc/ssh/sshd_config.d/99-deepeye.conf"
rm -f "$rootfs/etc/nginx/sites-enabled/default"
install -m 0644 "$script_dir/nginx-deepeye.conf" "$rootfs/etc/nginx/conf.d/deepeye.conf"
install -d -m 0750 -o root -g "$deep_gid" "$rootfs/etc/deepeye/tls"
chroot "$rootfs" openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=build-only \
  -keyout /etc/deepeye/tls/server.key -out /etc/deepeye/tls/server.crt >/dev/null 2>&1
printf 'build-only\n' | chroot "$rootfs" htpasswd -i -cB /etc/deepeye/nginx.htpasswd deepadmin >/dev/null
cat > "$rootfs/etc/sudoers.d/90-deepadmin" <<'EOF'
deepadmin ALL=(root) NOPASSWD: /usr/local/sbin/configure-deepeye-llm *, /usr/local/sbin/deepeye-set-password *, /usr/local/sbin/deepeye-verify *, /usr/bin/systemctl restart deepeye.service, /usr/bin/systemctl restart deepeye-llm-relay.service, /usr/bin/systemctl restart nginx.service, /usr/bin/journalctl -u deepeye.service *
EOF
chmod 0440 "$rootfs/etc/sudoers.d/90-deepadmin"
for unit in deepeye-firstboot.service deepeye-llm-relay.service deepeye.service nginx.service ssh.service; do chroot "$rootfs" systemctl enable "$unit"; done

echo '[6/9] Static security and secret acceptance'
chroot "$rootfs" node --version | grep -Fx "v$node_version"
chroot "$rootfs" node --check /usr/local/lib/deepeye/gpt-oss-relay.mjs
chroot "$rootfs" python3 -m py_compile /usr/local/lib/deepeye/deepeye-web.py
chroot "$rootfs" nginx -t
chroot "$rootfs" sshd -t
grep -Fq '127.0.0.1", 3333' "$rootfs/usr/local/lib/deepeye/deepeye-web.py"
grep -Fq 'proxy_pass http://127.0.0.1:3333' "$rootfs/etc/nginx/conf.d/deepeye.conf"
grep -Fq 'lock_model: true' "$rootfs/etc/deepeye/config.yaml"
grep -Fq 'model: gpt-oss-120b' "$rootfs/etc/deepeye/config.yaml"
grep -A2 '^compliance:' "$rootfs/etc/deepeye/config.yaml" | grep -Fq 'enabled: false'
if grep -RIE '(sk-[A-Za-z0-9_-]{16,}|GPT_OSS_API_KEY=[^[:space:]]{8,})' \
  "$rootfs/etc/deepeye" "$rootfs/usr/local/lib/deepeye" \
  "$rootfs/opt/deepeye/ai_providers" "$rootfs/opt/deepeye/deep_eye.py" \
  --exclude='test_*.py' --exclude='*.md'; then
  echo 'A secret-like value was found in the packaged runtime.' >&2
  exit 1
fi

echo '[7/9] Package inventory and cleanup'
chroot "$rootfs" apt-get clean
rm -rf "$rootfs/var/lib/apt/lists"/* "$rootfs/opt/deepeye/.git" "$rootfs/opt/deepeye/.pytest_cache"
rm -f "$rootfs/etc/machine-id"; : > "$rootfs/etc/machine-id"
rm -f "$rootfs/etc/deepeye/nginx.htpasswd" "$rootfs/etc/deepeye/tls/server.key" "$rootfs/etc/deepeye/tls/server.crt"
rm -f "$rootfs/var/lib/dbus/machine-id" "$rootfs/etc/ssh/ssh_host_"*
rm -f "$rootfs/usr/sbin/policy-rc.d"
rm -f "$rootfs/etc/resolv.conf"
if [[ -e "$work_dir/resolv.conf.original" ]]; then cp -a "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"; else : > "$rootfs/etc/resolv.conf"; fi
find "$rootfs/var/log" -type f -exec truncate -s 0 {} +
rm -rf "$rootfs/tmp"/* "$rootfs/var/tmp"/* "$rootfs/root/.cache" "$rootfs/var/lib/deepeye/home/.cache/pip"

echo '[8/9] Deterministic Proxmox template'
mountpoint -q "$rootfs/dev" && umount -l "$rootfs/dev"
mountpoint -q "$rootfs/sys" && umount -l "$rootfs/sys"
mountpoint -q "$rootfs/proc" && umount -l "$rootfs/proc"
mounts_active=0
tar --sort=name --mtime="@$source_date_epoch" --clamp-mtime --numeric-owner \
  --pax-option=delete=atime,delete=ctime -C "$rootfs" -cf - . | zstd -19 -T0 -o "$out_dir/$image_name"

echo '[9/9] Release evidence and checksums'
image_sha="$(sha256sum "$out_dir/$image_name" | cut -d' ' -f1)"
cp "$rootfs/usr/local/share/deepeye-python-lock.txt" "$out_dir/python-lock.txt"
cat > "$out_dir/BUILD-MANIFEST.json" <<EOF
{"schema":1,"image":"$image_name","sha256":"$image_sha","base":"$base_name","base_sha512":"$base_sha512","source_repository":"https://github.com/zakirkun/deep-eye","source_commit":"$source_commit","source_sha512":"$source_sha512","node":"$node_version","python":"$(chroot "$rootfs" python3 --version | awk '{print $2}')","model":"gpt-oss-120b","os":"Debian 13.6","build_epoch":$source_date_epoch}
EOF
cp "$script_dir/README_RU.md" "$script_dir/deploy-deepeye.sh" "$script_dir/deepeye-verify.sh" \
  "$script_dir/configure-deepeye-llm.sh" "$script_dir/deepeye-set-password.sh" "$out_dir/"
(cd "$out_dir" && sha256sum "$image_name" BUILD-MANIFEST.json python-lock.txt \
  deploy-deepeye.sh deepeye-verify.sh configure-deepeye-llm.sh deepeye-set-password.sh > SHA256SUMS)
echo "Built: $out_dir/$image_name"
