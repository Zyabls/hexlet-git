#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/etc/t3mp3st/t3mp3st.env
T3_HOME=/var/lib/t3mp3st/home
API=http://127.0.0.1:3333

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "Run with sudo: sudo t3mp3st-free-ai $*" >&2
    exit 1
  }
}

set_provider() {
  require_root "$@"
  local provider="$1"
  sed -i "s/^TEMPEST_DEFAULT_PROVIDER=.*/TEMPEST_DEFAULT_PROVIDER=${provider}/" "$ENV_FILE"
  systemctl restart t3mp3st
  echo "T3MP3ST default provider: $provider"
}

case "${1:-status}" in
  status)
    echo "== Services =="
    systemctl is-active t3mp3st ollama || true
    echo "== Codex authentication =="
    runuser -u t3mp3st -- env HOME="$T3_HOME" /usr/local/bin/codex login status || true
    echo "== Local Ollama models =="
    runuser -u ollama -- env HOME=/var/lib/ollama OLLAMA_HOST=127.0.0.1:11434 \
      OLLAMA_MODELS=/var/lib/ollama/models /usr/local/bin/ollama list || true
    echo "== T3MP3ST local agents =="
    curl --fail --silent "$API/api/agents/local/detect" | jq . || true
    ;;
  codex-login)
    require_root "$@"
    runuser -u t3mp3st -- env HOME="$T3_HOME" /usr/local/bin/codex login --device-auth
    systemctl restart t3mp3st
    sleep 3
    curl --fail --silent -X POST "$API/api/agents/local/connect" \
      -H 'Content-Type: application/json' \
      -d '{"id":"codex","replace":true,"ping":false}' | jq .
    ;;
  codex)
    set_provider codex
    ;;
  local)
    set_provider local
    ;;
  connect-codex)
    curl --fail --silent -X POST "$API/api/agents/local/connect" \
      -H 'Content-Type: application/json' \
      -d '{"id":"codex","replace":true,"ping":false}' | jq .
    ;;
  pull)
    require_root "$@"
    model="${2:?Usage: sudo t3mp3st-free-ai pull MODEL}"
    runuser -u ollama -- env HOME=/var/lib/ollama OLLAMA_HOST=127.0.0.1:11434 \
      OLLAMA_MODELS=/var/lib/ollama/models /usr/local/bin/ollama pull "$model"
    ;;
  *)
    cat <<'EOF'
Usage: t3mp3st-free-ai COMMAND

  status          show Codex, Ollama and T3MP3ST state
  codex-login     sign Codex CLI in with ChatGPT device code, then connect it
  connect-codex   connect an already-authenticated Codex CLI without a probe
  codex           use Codex/ChatGPT as the default provider (no Platform API key)
  local           use the embedded Ollama model as the default provider
  pull MODEL      download another Ollama model when egress is available
EOF
    exit 2
    ;;
esac

