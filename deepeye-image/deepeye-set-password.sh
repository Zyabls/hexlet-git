#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
password_file=${1:-}
if [[ -n "$password_file" ]]; then
  [[ -f "$password_file" ]] || { echo 'Password file not found.' >&2; exit 2; }
  password="$(tr -d '\r\n' < "$password_file")"
else
  read -rsp 'New Deep Eye web password: ' password; echo
  read -rsp 'Repeat password: ' confirmation; echo
  [[ "$password" == "$confirmation" ]] || { echo 'Passwords do not match.' >&2; exit 2; }
  unset confirmation
fi
[[ ${#password} -ge 12 ]] || { echo 'Use at least 12 characters.' >&2; exit 2; }
printf '%s\n' "$password" | htpasswd -i -cB /etc/deepeye/nginx.htpasswd deepadmin >/dev/null
unset password
chown root:www-data /etc/deepeye/nginx.htpasswd
chmod 0640 /etc/deepeye/nginx.htpasswd
nginx -t
systemctl reload nginx.service
echo 'Deep Eye web password updated for user deepadmin.'
