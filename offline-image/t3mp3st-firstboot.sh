#!/usr/bin/env bash
set -Eeuo pipefail

install -d -m 0700 -o t3admin -g t3admin /home/t3admin/.ssh
if [[ -s /root/.ssh/authorized_keys ]]; then
  install -m 0600 -o t3admin -g t3admin \
    /root/.ssh/authorized_keys /home/t3admin/.ssh/authorized_keys
else
  echo "No SSH public key was injected by Proxmox; use pct exec to add one." >&2
fi

ssh-keygen -A
install -d -m 0750 -o t3mp3st -g t3mp3st /var/lib/t3mp3st
touch /var/lib/t3mp3st/.firstboot-done
chown t3mp3st:t3mp3st /var/lib/t3mp3st/.firstboot-done

