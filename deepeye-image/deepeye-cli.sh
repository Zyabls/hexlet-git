#!/usr/bin/env bash
set -Eeuo pipefail

app_root=/opt/deepeye
python_bin="$app_root/venv/bin/python"
default_config=/etc/deepeye/config.yaml

[[ -x "$python_bin" && -r "$app_root/deep_eye.py" ]] || {
  echo 'Deep Eye runtime is incomplete under /opt/deepeye.' >&2
  exit 127
}

export PYTHONPATH="$app_root${PYTHONPATH:+:$PYTHONPATH}"
export PLAYWRIGHT_BROWSERS_PATH=/opt/deepeye/playwright
export PATH="/opt/deepeye/venv/bin:/usr/local/bin:/usr/bin:/bin"

has_config=0
for argument in "$@"; do
  case "$argument" in
    -c|--config|--config=*) has_config=1 ;;
  esac
done

cd "$app_root"
if (( has_config )); then
  exec "$python_bin" "$app_root/deep_eye.py" "$@"
fi
exec "$python_bin" "$app_root/deep_eye.py" --config "$default_config" "$@"
