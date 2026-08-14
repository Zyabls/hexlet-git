#!/usr/bin/env bash
set -Eeuo pipefail

marker=/var/lib/deepeye/.firstboot-complete
[[ ! -e "$marker" ]] || exit 0

install -d -m 0750 -o deepeye -g deepeye /var/lib/deepeye/home
install -d -m 2770 -o deepeye -g deepeye \
  /var/lib/deepeye/state /var/lib/deepeye/reports /var/lib/deepeye/logs \
  /var/lib/deepeye/logs/jobs /var/lib/deepeye/data /var/lib/deepeye/evidence

ssh-keygen -A
install -d -m 0700 -o deepadmin -g deepadmin /home/deepadmin/.ssh
if [[ -s /root/.ssh/authorized_keys && ! -s /home/deepadmin/.ssh/authorized_keys ]]; then
  install -m 0600 -o deepadmin -g deepadmin \
    /root/.ssh/authorized_keys /home/deepadmin/.ssh/authorized_keys
fi

touch "$marker"
chmod 0600 "$marker"
systemctl disable deepeye-firstboot.service >/dev/null 2>&1 || true
