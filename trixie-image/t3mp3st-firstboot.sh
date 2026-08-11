#!/usr/bin/env bash
set -Eeuo pipefail

marker=/var/lib/t3mp3st/.firstboot-complete
[[ ! -e "$marker" ]] || exit 0

ssh-keygen -A
install -d -m 0700 -o t3admin -g t3admin /home/t3admin/.ssh
if [[ -s /root/.ssh/authorized_keys && ! -s /home/t3admin/.ssh/authorized_keys ]]; then
  install -m 0600 -o t3admin -g t3admin /root/.ssh/authorized_keys /home/t3admin/.ssh/authorized_keys
fi

install -d -m 0750 -o root -g t3mp3st /etc/t3mp3st/tls
if [[ ! -s /etc/t3mp3st/tls/server.key ]]; then
  hostname_fqdn="$(hostname -f 2>/dev/null || hostname)"
  san="DNS:${hostname_fqdn},DNS:$(hostname),IP:127.0.0.1"
  while IFS= read -r address; do san+=",IP:${address}"; done < <(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print a[1]}')
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=${hostname_fqdn}" \
    -addext "subjectAltName=${san}" \
    -keyout /etc/t3mp3st/tls/server.key -out /etc/t3mp3st/tls/server.crt
  chmod 0640 /etc/t3mp3st/tls/server.key
  chmod 0644 /etc/t3mp3st/tls/server.crt
  chown root:t3mp3st /etc/t3mp3st/tls/server.key /etc/t3mp3st/tls/server.crt
fi

if [[ ! -s /etc/t3mp3st/nginx.htpasswd ]]; then
  initial_password="$(openssl rand -hex 18)"
  printf '%s\n' "$initial_password" | htpasswd -i -cB /etc/t3mp3st/nginx.htpasswd t3admin >/dev/null
  install -m 0600 /dev/null /root/t3mp3st-initial-credentials.txt
  {
    printf 'Web user: t3admin\n'
    printf 'Web password: %s\n' "$initial_password"
    printf 'Change: htpasswd /etc/t3mp3st/nginx.htpasswd t3admin\n'
  } > /root/t3mp3st-initial-credentials.txt
  unset initial_password
fi
chmod 0640 /etc/t3mp3st/nginx.htpasswd
chown root:www-data /etc/t3mp3st/nginx.htpasswd

nginx -t
touch "$marker"
chmod 0600 "$marker"
systemctl disable t3mp3st-firstboot.service >/dev/null 2>&1 || true
