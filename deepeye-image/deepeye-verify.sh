#!/usr/bin/env bash
set -Eeuo pipefail

live_llm=0
stability=0
for argument in "$@"; do
  case "$argument" in
    --live-llm) live_llm=1 ;;
    --stability) stability=1 ;;
    -h|--help)
      echo 'Usage: deepeye-verify [--live-llm] [--stability]'
      exit 0
      ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="/var/lib/deepeye/evidence/acceptance-$stamp"
report_dir="/var/lib/deepeye/reports/acceptance-$stamp"
fixture="$(mktemp -d -t deepeye-verify.XXXXXXXX)"
fixture_pid=''
failures=0
cleanup() {
  [[ -z "$fixture_pid" ]] || kill "$fixture_pid" >/dev/null 2>&1 || true
  rm -rf -- "$fixture"
}
trap cleanup EXIT
install -d -m 2770 -o deepeye -g deepeye "$run_dir" "$report_dir"

check() {
  label=$1
  shift
  if "$@"; then
    echo "[PASS] $label"
  else
    echo "[FAIL] $label"
    failures=$((failures + 1))
  fi
}

as_admin() {
  runuser -u deepadmin -- env \
    HOME=/home/deepadmin \
    PATH=/opt/deepeye/venv/bin:/usr/local/bin:/usr/bin:/bin \
    PLAYWRIGHT_BROWSERS_PATH=/opt/deepeye/playwright "$@"
}

echo "Deep Eye CLI-only acceptance $stamp"
check 'Debian 13' grep -Fq 'VERSION_ID="13"' /etc/os-release
check 'SSH active' systemctl is-active --quiet ssh.service
check 'gpt-oss relay active' systemctl is-active --quiet deepeye-llm-relay.service
check 'no failed systemd units' bash -c 'test "$(systemctl --failed --no-legend | wc -l)" -eq 0'
check 'nginx package absent' bash -c '! command -v nginx >/dev/null 2>&1'
check 'web wrapper absent' test ! -e /usr/local/lib/deepeye/deepeye-web.py
check 'no HTTP/HTTPS/control-plane listeners' bash -c \
  "! ss -lntH | awk '{print \$4}' | grep -Eq ':(80|443|3333)$'"
check 'relay loopback-only' bash -c \
  "ss -lntH '( sport = :18080 )' | grep -q '127.0.0.1:18080' && ! ss -lntH '( sport = :18080 )' | grep -qE '(0\\.0\\.0\\.0|\\[::\\]):18080'"
check 'sshd configuration' sshd -t
check 'CLI launcher on PATH' as_admin bash -c 'test "$(command -v deepeye)" = /usr/local/bin/deepeye'
check 'Deep Eye CLI version' as_admin deepeye --version
check 'Deep Eye CLI default config' as_admin bash -c 'deepeye --help | grep -q -- --config'
check 'deepadmin is in deepeye group' bash -c 'id -nG deepadmin | grep -qw deepeye'
check 'deepadmin can write reports' as_admin test -w /var/lib/deepeye/reports
check 'deepadmin can write logs' as_admin test -w /var/lib/deepeye/logs

while IFS= read -r tool; do
  check "required command from SSH user: $tool" as_admin bash -c "command -v -- '$tool' >/dev/null"
done < <(jq -r '.commands[]' /usr/local/share/deepeye-required-tools.json)
check 'required Python imports from SSH user' as_admin /opt/deepeye/venv/bin/python -c \
  'import importlib,json; p=json.load(open("/usr/local/share/deepeye-required-tools.json")); [importlib.import_module(name) for name in p["pythonImports"]]'
check 'OpenAI-compatible regression' as_admin bash -c \
  'cd /opt/deepeye && /opt/deepeye/venv/bin/pytest -q tests/test_openai_compatible_provider.py'
check 'Chromium launches from SSH user context' as_admin /opt/deepeye/venv/bin/python -c \
  'from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-setuid-sandbox"]); print(b.version); b.close(); p.stop()'

cat > "$fixture/vulnerable_fixture.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        value = parse_qs(urlsplit(self.path).query).get('q', [''])[0]
        body = f'<!doctype html><title>Deep Eye acceptance fixture</title><main>{value}</main>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_args):
        pass


HTTPServer(('127.0.0.1', 18081), Fixture).serve_forever()
PY
python3 "$fixture/vulnerable_fixture.py" > "$run_dir/fixture-http.log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 30); do curl -fsS 'http://127.0.0.1:18081/?q=seed' >/dev/null && break; sleep 0.2; done

/opt/deepeye/venv/bin/python - /etc/deepeye/config.yaml "$run_dir/scan.yaml" "$report_dir" "$run_dir/deepeye.log" <<'PY'
import sys, yaml
source = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
source['vulnerability_scanner']['payload_generation']['use_ai'] = False
source['vulnerability_scanner']['enabled_checks'] = ['xss']
source['scanner'].update({'default_threads': 1, 'default_depth': 0, 'max_urls': 1, 'enable_recon': False})
source['advanced'].update({'enable_javascript_rendering': True, 'screenshot_enabled': False})
source['templates']['enabled'] = False
source['ai_triage']['enabled'] = False
source['bug_bounty']['enabled'] = False
source['reporting'].update({'output_directory': sys.argv[3], 'formats': ['html', 'json']})
source['logging'].update({'log_file': sys.argv[4]})
source['database']['enabled'] = False
yaml.safe_dump(source, open(sys.argv[2], 'w', encoding='utf-8'), sort_keys=False)
PY
chown deepadmin:deepeye "$run_dir/scan.yaml"
check 'real bounded CLI scan as deepadmin' as_admin timeout 300 deepeye --no-banner \
  --config "$run_dir/scan.yaml" --url 'http://127.0.0.1:18081/?q=seed' --formats html,json
check 'target-named HTML report' bash -c "find '$report_dir' -type f -name '*127.0.0.1_18081*.html' | grep -q ."
check 'target-named JSON report' bash -c "find '$report_dir' -type f -name '*127.0.0.1_18081*.json' | grep -q ."
check 'report contains scanned resource' grep -Rqs '127.0.0.1:18081' "$report_dir"
check 'report contains browser-verified XSS' grep -Rqs 'Cross-Site Scripting (XSS) - Browser Verified' "$report_dir"
check 'scan log has no pending Playwright task' bash -c "! grep -qs 'Task was destroyed but it is pending' '$run_dir/deepeye.log'"

if (( live_llm )); then
  check 'relay exposes gpt-oss-120b' bash -c \
    "curl -fsS http://127.0.0.1:18080/v1/models > '$run_dir/models.json' && jq -e 'any(.data[]?; .id == \"gpt-oss-120b\")' '$run_dir/models.json' >/dev/null"
  check 'Deep Eye live gpt-oss response' as_admin timeout 360 /opt/deepeye/venv/bin/python -c \
    "import yaml; from ai_providers.openai_provider import OpenAIProvider; c=yaml.safe_load(open('/etc/deepeye/config.yaml'))['ai_providers']['openai']; r=OpenAIProvider(c).generate('Reply with exactly DEEPEYE_LLM_OK', max_tokens=64); assert 'DEEPEYE_LLM_OK' in r; print(r)"
fi

if (( stability )); then
  check '100 parallel CLI launches' bash -c \
    "seq 1 100 | xargs -P10 -n1 sh -c 'runuser -u deepadmin -- env HOME=/home/deepadmin PATH=/usr/local/bin:/usr/bin:/bin deepeye --version >/dev/null' _"
  relay_pid_before="$(systemctl show -p MainPID --value deepeye-llm-relay.service)"
  systemctl restart deepeye-llm-relay.service
  check 'relay clean restart' systemctl is-active --quiet deepeye-llm-relay.service
  relay_pid_after="$(systemctl show -p MainPID --value deepeye-llm-relay.service)"
  check 'relay PID changed after restart' test "$relay_pid_before" != "$relay_pid_after"
fi

find "$run_dir" "$report_dir" -type f -print0 | sort -z | xargs -0 sha256sum > "$run_dir/SHA256SUMS"
echo "Evidence: $run_dir"
echo "Reports: $report_dir"
if (( failures )); then
  echo "$failures acceptance checks failed" >&2
  exit 1
fi
echo 'All Deep Eye CLI-only acceptance checks passed.'
