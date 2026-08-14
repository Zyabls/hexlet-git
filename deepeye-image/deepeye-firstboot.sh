#!/usr/bin/env bash
set -Eeuo pipefail

marker=/var/lib/deepeye/.firstboot-complete
[[ ! -e "$marker" ]] || exit 0

install -d -m 0750 -o deepeye -g deepeye \
  /var/lib/deepeye/home /var/lib/deepeye/state /var/lib/deepeye/reports \
  /var/lib/deepeye/logs /var/lib/deepeye/logs/jobs /var/lib/deepeye/data

ssh-keygen -A
install -d -m 0700 -o deepadmin -g deepadmin /home/deepadmin/.ssh
if [[ -s /root/.ssh/authorized_keys && ! -s /home/deepadmin/.ssh/authorized_keys ]]; then
  install -m 0600 -o deepadmin -g deepadmin /root/.ssh/authorized_keys /home/deepadmin/.ssh/authorized_keys
fi

install -d -m 0750 -o root -g deepeye /etc/deepeye/tls
if [[ ! -s /etc/deepeye/tls/server.key ]]; then
  hostname_fqdn="$(hostname -f 2>/dev/null || hostname)"
  san="DNS:${hostname_fqdn},DNS:$(hostname),IP:127.0.0.1"
  while IFS= read -r address; do san+=",IP:${address}"; done < <(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print a[1]}')
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=${hostname_fqdn}" -addext "subjectAltName=${san}" \
    -keyout /etc/deepeye/tls/server.key -out /etc/deepeye/tls/server.crt
  chmod 0640 /etc/deepeye/tls/server.key
  chmod 0644 /etc/deepeye/tls/server.crt
  chown root:deepeye /etc/deepeye/tls/server.key /etc/deepeye/tls/server.crt
fi

if [[ ! -s /etc/deepeye/nginx.htpasswd ]]; then
  initial_password="$(openssl rand -hex 18)"
  printf '%s\n' "$initial_password" | htpasswd -i -cB /etc/deepeye/nginx.htpasswd deepadmin >/dev/null
  install -m 0600 /dev/null /root/deepeye-initial-credentials.txt
  {
    printf 'Web user: deepadmin\n'
    printf 'Web password: %s\n' "$initial_password"
    printf 'Change: htpasswd /etc/deepeye/nginx.htpasswd deepadmin\n'
  } > /root/deepeye-initial-credentials.txt
  unset initial_password
fi
chown root:www-data /etc/deepeye/nginx.htpasswd
chmod 0640 /etc/deepeye/nginx.htpasswd
chmod 0751 /etc/deepeye

nginx -t
touch "$marker"
chmod 0600 "$marker"
systemctl disable deepeye-firstboot.service >/dev/null 2>&1 || true
