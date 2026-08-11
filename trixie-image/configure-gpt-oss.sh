#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
config=/etc/t3mp3st/relay.env
upstream="${GPT_OSS_UPSTREAM:-https://llm.enplus.group/v1}"
model="${GPT_OSS_MODEL:-gpt-oss-120b}"
tls_mode="${GPT_OSS_TLS_MODE:-strict}"

if [[ ${1:-} == --key-file ]]; then
  [[ $# -eq 2 && -f $2 && ! -L $2 ]] || { echo 'Usage: configure-gpt-oss [--key-file ROOT_ONLY_FILE]' >&2; exit 2; }
  key_file_mode="$(stat -c '%a' "$2")"
  key_file_uid="$(stat -c '%u' "$2")"
  [[ $key_file_uid == 0 && ( $key_file_mode == 600 || $key_file_mode == 400 ) ]] || { echo 'Key file must be root-owned with mode 0600 or 0400.' >&2; exit 2; }
  IFS= read -r key < "$2"
elif [[ $# -eq 0 ]]; then
  read -r -s -p 'gpt-oss API key: ' key
  printf '\n'
else
  echo 'Usage: configure-gpt-oss [--key-file ROOT_ONLY_FILE]' >&2
  exit 2
fi
[[ "$key" != *[$'\r\n\t ']* && ${#key} -ge 12 ]] || { echo 'Invalid key format.' >&2; exit 2; }
[[ "$upstream" == https://* ]] || { echo 'Upstream must use HTTPS.' >&2; exit 2; }
[[ "$tls_mode" =~ ^(strict|custom-ca|insecure-host)$ ]] || { echo 'Invalid TLS mode.' >&2; exit 2; }

umask 0077
tmp="$(mktemp /etc/t3mp3st/relay.env.XXXXXX)"
trap 'rm -f -- "$tmp"' EXIT
{
  printf 'GPT_OSS_UPSTREAM=%s\n' "$upstream"
  printf 'GPT_OSS_MODEL=%s\n' "$model"
  printf 'GPT_OSS_API_KEY=%s\n' "$key"
  printf 'GPT_OSS_TLS_MODE=%s\n' "$tls_mode"
  printf 'GPT_OSS_CA_FILE=%s\n' "${GPT_OSS_CA_FILE:-/etc/t3mp3st/corporate-ca.pem}"
} > "$tmp"
chown root:t3mp3st "$tmp"
chmod 0640 "$tmp"
mv -f -- "$tmp" "$config"
trap - EXIT
unset key

systemctl restart t3mp3st-llm-relay.service t3mp3st.service
for _ in $(seq 1 30); do
  curl --silent --fail http://127.0.0.1:18080/v1/models | jq -e --arg model "$model" \
    'any(.data[]?; .id == $model)' >/dev/null 2>&1 && break
  sleep 1
done
curl --silent --fail http://127.0.0.1:18080/v1/models | jq -e --arg model "$model" \
  'any(.data[]?; .id == $model)' >/dev/null
echo "Configured and verified model: $model"
echo 'Run: sudo t3mp3st-verify --live-llm'
