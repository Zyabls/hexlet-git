#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "build.sh must run as root" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/out}"

T3MP3ST_COMMIT="afc9dad1b27e438e36fdb0fd80c4dec26f3a02aa"
T3MP3ST_SHORT="afc9dad1"
NODE_VERSION="24.16.0"
NODE_SHA256="d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"
CODEX_VERSION="0.146.0"
BUNDLE_NAME="t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz"
BUNDLE_SHA256="76328c2d38f9d739a8771955fa9f59c365f0cfffb890a2dd7fe411deb02d71fa"
IMAGE_NAME="t3mp3st-debian12-pve-offline-amd64-afc9dad1.tar.zst"

WORK_DIR="$(mktemp -d -t t3mp3st-lxc-build.XXXXXXXX)"
ROOTFS="$WORK_DIR/rootfs"
PAYLOAD_DIR="$WORK_DIR/payload"
MOUNTS_ACTIVE=0

unmount_chroot() {
  if [[ $MOUNTS_ACTIVE -eq 1 ]]; then
    mountpoint -q "$ROOTFS/dev" && umount -l "$ROOTFS/dev" || true
    mountpoint -q "$ROOTFS/sys" && umount -l "$ROOTFS/sys" || true
    mountpoint -q "$ROOTFS/proc" && umount -l "$ROOTFS/proc" || true
    MOUNTS_ACTIVE=0
  fi
}

cleanup() {
  unmount_chroot
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p -- "$ROOTFS" "$PAYLOAD_DIR" "$OUT_DIR"

echo "[1/9] Installing trusted build dependencies on the runner"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  debootstrap zstd ca-certificates curl xz-utils git acl

echo "[2/9] Bootstrapping signed Debian 12 root filesystem"
debootstrap --variant=minbase --arch=amd64 bookworm "$ROOTFS" https://deb.debian.org/debian

cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian bookworm main
deb https://deb.debian.org/debian bookworm-updates main
deb https://security.debian.org/debian-security bookworm-security main
EOF

rm -f "$ROOTFS/etc/resolv.conf"
cp --dereference /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

mount -t proc proc "$ROOTFS/proc"
mount --rbind /sys "$ROOTFS/sys"
mount --make-rslave "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev"
MOUNTS_ACTIVE=1

echo "[3/9] Installing all OS packages into the image"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  apt-get update
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
    systemd-sysv dbus openssh-server sudo ca-certificates curl xz-utils tar git \
    build-essential dnsutils whois nmap jq iproute2 iputils-ping procps less \
    vim-tiny locales ifupdown isc-dhcp-client python3 python3-venv pipx \
    ripgrep netcat-openbsd lsof tcpdump

printf 'en_US.UTF-8 UTF-8\n' > "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen en_US.UTF-8
printf 'LANG=en_US.UTF-8\n' > "$ROOTFS/etc/default/locale"
ln -sfn /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
printf 'Etc/UTC\n' > "$ROOTFS/etc/timezone"

echo "[4/9] Embedding verified Node.js and the supplied T3MP3ST source"
NODE_ARCHIVE="node-v${NODE_VERSION}-linux-x64.tar.xz"
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}" \
  --output "$WORK_DIR/$NODE_ARCHIVE"
printf '%s  %s\n' "$NODE_SHA256" "$WORK_DIR/$NODE_ARCHIVE" | sha256sum --check --strict
tar -xJf "$WORK_DIR/$NODE_ARCHIVE" -C "$ROOTFS/opt"
for binary in node npm npx corepack; do
  ln -sfn "/opt/node-v${NODE_VERSION}-linux-x64/bin/$binary" \
    "$ROOTFS/usr/local/bin/$binary"
done

BUNDLE_PATH="$REPO_DIR/$BUNDLE_NAME"
[[ -f "$BUNDLE_PATH" ]] || {
  echo "Missing source bundle: $BUNDLE_PATH" >&2
  exit 1
}
printf '%s  %s\n' "$BUNDLE_SHA256" "$BUNDLE_PATH" | sha256sum --check --strict
tar -xzf "$BUNDLE_PATH" -C "$PAYLOAD_DIR"
SOURCE_ARCHIVE="$PAYLOAD_DIR/t3mp3st-proxmox-lxc-20260803/payload/t3mp3st-src-afc9dad1.tar.gz"
[[ -f "$SOURCE_ARCHIVE" ]] || {
  echo "Missing inner T3MP3ST source archive" >&2
  exit 1
}

RELEASE_DIR="$ROOTFS/opt/t3mp3st-$T3MP3ST_SHORT"
mkdir -p "$RELEASE_DIR"
tar -xzf "$SOURCE_ARCHIVE" -C "$RELEASE_DIR" --strip-components=1

echo "[5/9] Creating service accounts and compiling T3MP3ST offline payload"
chroot "$ROOTFS" useradd --system --create-home \
  --home-dir /var/lib/t3mp3st/home --shell /bin/bash t3mp3st
chroot "$ROOTFS" useradd --create-home --shell /bin/bash t3admin
chroot "$ROOTFS" passwd --lock t3admin

install -d -m 0750 -o "$(chroot "$ROOTFS" id -u t3mp3st)" \
  -g "$(chroot "$ROOTFS" id -g t3mp3st)" \
  "$ROOTFS/var/lib/t3mp3st" \
  "$ROOTFS/var/lib/t3mp3st/home" \
  "$ROOTFS/var/lib/t3mp3st/state" \
  "$ROOTFS/var/lib/t3mp3st/reports" \
  "$ROOTFS/var/lib/t3mp3st/evidence"

install -d -m 0750 "$ROOTFS/etc/sudoers.d"
printf 't3admin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$ROOTFS/etc/sudoers.d/90-t3admin"
chmod 0440 "$ROOTFS/etc/sudoers.d/90-t3admin"

chown -R "$(chroot "$ROOTFS" id -u t3mp3st):$(chroot "$ROOTFS" id -g t3mp3st)" "$RELEASE_DIR"
chroot "$ROOTFS" /usr/sbin/runuser -u t3mp3st -- \
  /usr/bin/env HOME=/var/lib/t3mp3st/home \
  NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false \
  /usr/local/bin/npm --prefix "/opt/t3mp3st-$T3MP3ST_SHORT" ci --ignore-scripts
chroot "$ROOTFS" /usr/sbin/runuser -u t3mp3st -- \
  /usr/bin/env HOME=/var/lib/t3mp3st/home \
  NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false \
  /usr/local/bin/npm --prefix "/opt/t3mp3st-$T3MP3ST_SHORT" run build
chown -R root:root "$RELEASE_DIR"
ln -sfn "/opt/t3mp3st-$T3MP3ST_SHORT" "$ROOTFS/opt/t3mp3st"
ln -sfn /var/lib/t3mp3st/reports "$RELEASE_DIR/reports"
ln -sfn /var/lib/t3mp3st/evidence "$RELEASE_DIR/evidence"

echo "[6/9] Installing Codex CLI into the image (without credentials)"
chroot "$ROOTFS" /usr/bin/env \
  NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false \
  /usr/local/bin/npm install --global --prefix /usr/local \
  "@openai/codex@$CODEX_VERSION"
chroot "$ROOTFS" /usr/local/bin/node --version
chroot "$ROOTFS" /usr/local/bin/codex --version
chroot "$ROOTFS" /usr/local/bin/node --check /opt/t3mp3st/dist/server.js

echo "[7/9] Configuring systemd, SSH key-only access and first boot"
install -d -m 0755 "$ROOTFS/etc/t3mp3st" "$ROOTFS/etc/ssh/sshd_config.d"
install -m 0640 -o root -g "$(chroot "$ROOTFS" getent group t3mp3st | cut -d: -f3)" \
  "$SCRIPT_DIR/t3mp3st.env" "$ROOTFS/etc/t3mp3st/t3mp3st.env"
install -m 0644 "$SCRIPT_DIR/t3mp3st.service" \
  "$ROOTFS/etc/systemd/system/t3mp3st.service"
install -m 0644 "$SCRIPT_DIR/t3mp3st-firstboot.service" \
  "$ROOTFS/etc/systemd/system/t3mp3st-firstboot.service"
install -m 0755 "$SCRIPT_DIR/t3mp3st-firstboot.sh" \
  "$ROOTFS/usr/local/sbin/t3mp3st-firstboot"

cat > "$ROOTFS/etc/ssh/sshd_config.d/99-t3mp3st-hardening.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding yes
EOF

cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

printf 't3mp3st\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 t3mp3st
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > "$ROOTFS/etc/t3mp3st/BUILD_INFO" <<EOF
Image: $IMAGE_NAME
Base: Debian 12 bookworm amd64
T3MP3ST commit: $T3MP3ST_COMMIT
Node.js: $NODE_VERSION
Codex CLI: $CODEX_VERSION
Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Credentials: none embedded
EOF

systemctl --root="$ROOTFS" enable ssh.service
systemctl --root="$ROOTFS" enable t3mp3st-firstboot.service
systemctl --root="$ROOTFS" enable t3mp3st.service

echo "[8/9] Removing build caches, machine identity and generated secrets"
chroot "$ROOTFS" apt-get clean
rm -rf \
  "$ROOTFS/var/lib/apt/lists/"* \
  "$ROOTFS/var/cache/apt/"* \
  "$ROOTFS/var/cache/debconf/"*old \
  "$ROOTFS/var/lib/t3mp3st/home/.npm" \
  "$ROOTFS/root/.npm" \
  "$ROOTFS/tmp/"* \
  "$ROOTFS/var/tmp/"* \
  "$ROOTFS/var/log/"*.log \
  "$ROOTFS/var/log/apt/"* \
  "$ROOTFS/var/log/journal/"*
rm -f \
  "$ROOTFS/usr/sbin/policy-rc.d" \
  "$ROOTFS/etc/ssh/ssh_host_"* \
  "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"
ln -sfn /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"
printf 'nameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"

credential_hit="$(find "$ROOTFS" \( -path '*/.codex/auth.json' -o -name '.credentials.json' \) -print -quit)"
if [[ -n "$credential_hit" ]]; then
  echo "Credential-like file found in image: $credential_hit; refusing to publish" >&2
  exit 1
fi

for required in \
  /opt/t3mp3st/dist/server.js \
  /opt/t3mp3st/node_modules \
  /usr/local/bin/node \
  /usr/local/bin/codex \
  /etc/systemd/system/t3mp3st.service \
  /usr/local/sbin/t3mp3st-firstboot; do
  chroot "$ROOTFS" test -e "$required" || {
    echo "Required image path missing: $required" >&2
    exit 1
  }
done

unmount_chroot

echo "[9/9] Packing and validating Proxmox vzdump-compatible rootfs"
rm -f "$OUT_DIR/$IMAGE_NAME" "$OUT_DIR/$IMAGE_NAME.sha256"
tar --numeric-owner --xattrs --acls -C "$ROOTFS" \
  -I 'zstd -19 -T0' -cpf "$OUT_DIR/$IMAGE_NAME" .
zstd --test "$OUT_DIR/$IMAGE_NAME"
(
  cd "$OUT_DIR"
  sha256sum "$IMAGE_NAME" > "$IMAGE_NAME.sha256"
)
install -m 0644 "$SCRIPT_DIR/INSTALL_PROXMOX_RU.txt" "$OUT_DIR/INSTALL_PROXMOX_RU.txt"

tar -tf "$OUT_DIR/$IMAGE_NAME" > "$WORK_DIR/image-contents.txt"
grep -Fxq './opt/t3mp3st-afc9dad1/dist/server.js' "$WORK_DIR/image-contents.txt"
grep -Fxq './etc/systemd/system/t3mp3st.service' "$WORK_DIR/image-contents.txt"

echo "Build complete:"
ls -lh "$OUT_DIR/$IMAGE_NAME" "$OUT_DIR/$IMAGE_NAME.sha256" "$OUT_DIR/INSTALL_PROXMOX_RU.txt"
cat "$OUT_DIR/$IMAGE_NAME.sha256"
