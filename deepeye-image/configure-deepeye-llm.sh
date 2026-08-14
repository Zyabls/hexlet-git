#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage (run inside the Deep Eye CT as root):
  configure-deepeye-llm --key-file FILE [--upstream URL] [--tls-mode strict|custom-ca|insecure-host] [--ca-file FILE]

The API key is read from a root-only file and never passed in the process list.
Default upstream: https://llm.enplus.group/v1
Model is locked to gpt-oss-120b.
EOF
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
key_file=''
upstream='https://llm.enplus.group/v1'
tls_mode='strict'
ca_file='/etc/deepeye/corporate-ca.pem'
while (($#)); do
  case "$1" in
    --key-file) key_file=${2:-}; shift 2 ;;
    --upstream) upstream=${2:-}; shift 2 ;;
    --tls-mode) tls_mode=${2:-}; shift 2 ;;
    --ca-file) ca_file=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -f "$key_file" ]] || { echo 'A readable --key-file is required.' >&2; exit 2; }
[[ "$upstream" =~ ^https://[^[:space:]]+$ ]] || { echo 'Upstream must use HTTPS.' >&2; exit 2; }
[[ "$tls_mode" =~ ^(strict|custom-ca|insecure-host)$ ]] || { echo 'Invalid TLS mode.' >&2; exit 2; }
[[ "$tls_mode" != custom-ca || -s "$ca_file" ]] || { echo 'Custom CA file is missing.' >&2; exit 2; }
api_key="$(tr -d '\r\n' < "$key_file")"
[[ ${#api_key} -ge 8 ]] || { echo 'API key is unexpectedly short.' >&2; exit 2; }

install -d -m 0751 -o root -g deepeye /etc/deepeye
temporary="$(mktemp /etc/deepeye/relay.env.XXXXXXXX)"
trap 'rm -f -- "$temporary"' EXIT
{
  printf 'GPT_OSS_UPSTREAM=%s\n' "$upstream"
  printf 'GPT_OSS_MODEL=gpt-oss-120b\n'
  printf 'GPT_OSS_API_KEY=%s\n' "$api_key"
  printf 'GPT_OSS_TLS_MODE=%s\n' "$tls_mode"
  printf 'GPT_OSS_CA_FILE=%s\n' "$ca_file"
  printf 'NO_PROXY=127.0.0.1,localhost\nno_proxy=127.0.0.1,localhost\n'
} > "$temporary"
unset api_key
chown root:deepeye "$temporary"
chmod 0640 "$temporary"
mv -f -- "$temporary" /etc/deepeye/relay.env
trap - EXIT
systemctl restart deepeye-llm-relay.service deepeye.service
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18080/v1/models >/tmp/deepeye-models.json; then break; fi
  sleep 1
done
jq -e 'any(.data[]?; .id == "gpt-oss-120b")' /tmp/deepeye-models.json >/dev/null
rm -f /tmp/deepeye-models.json
echo 'Deep Eye LLM configured: gpt-oss-120b through the loopback relay.'
