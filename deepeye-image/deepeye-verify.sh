#!/usr/bin/env bash
set -Eeuo pipefail

live_llm=0
stability=0
for arg in "$@"; do
  case "$arg" in
    --live-llm) live_llm=1 ;;
    --stability) stability=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="/var/lib/deepeye/logs/acceptance-$timestamp"
report="/var/lib/deepeye/reports/acceptance-$timestamp.md"
install -d -m 0750 -o deepeye -g deepeye "$run_dir" "$(dirname "$report")"
exec > >(tee "$run_dir/verify.log") 2>&1
failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

echo "Deep Eye acceptance $timestamp"
check 'Debian 13' grep -q '^VERSION_ID="13"' /etc/os-release
check 'Deep Eye service active' systemctl is-active --quiet deepeye.service
check 'gpt-oss relay active' systemctl is-active --quiet deepeye-llm-relay.service
check 'nginx active' systemctl is-active --quiet nginx.service
check 'SSH active' systemctl is-active --quiet ssh.service
failed_units="$(systemctl --failed --no-legend | wc -l)"
check 'no failed systemd units' test "$failed_units" -eq 0
check 'backend loopback-only' bash -c "ss -lntH '( sport = :3333 )' | grep -q '127.0.0.1:3333' && ! ss -lntH '( sport = :3333 )' | grep -qE '(0\.0\.0\.0|\[::\]):3333'"
check 'relay loopback-only' bash -c "ss -lntH '( sport = :18080 )' | grep -q '127.0.0.1:18080'"
check 'HTTP redirects to HTTPS' bash -c "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^301$'"
check 'HTTPS rejects unauthenticated access' bash -c "curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1/ | grep -q '^401$'"
check 'nginx configuration' nginx -t
check 'sshd configuration' sshd -t

verify_password="$(openssl rand -hex 18)"
printf '%s\n' "$verify_password" | htpasswd -i /etc/deepeye/nginx.htpasswd deepverify >/dev/null
curl_config="$(mktemp)"
chmod 0600 "$curl_config"
printf 'insecure\nsilent\nshow-error\nuser = "deepverify:%s"\n' "$verify_password" > "$curl_config"
check 'authenticated web UI' curl --config "$curl_config" --fail https://127.0.0.1/ -o "$run_dir/index.html"
check 'authenticated health proxy' bash -c "curl --config '$curl_config' --fail https://127.0.0.1/api/health > '$run_dir/health.json' && jq -e '.ok == true and .model == \"gpt-oss-120b\" and .sourceCommit == \"e98a361ee38ec65660ce585ff6789017a2d7a466\"' '$run_dir/health.json' >/dev/null"
check 'direct backend mutation denied' bash -c "curl -sS -o '$run_dir/direct-post.json' -w '%{http_code}' -H 'content-type: application/json' --data '{}' http://127.0.0.1:3333/api/scans | grep -q '^403$'"
check 'nginx private-target guard' bash -c "curl --config '$curl_config' -sS -o '$run_dir/private-target.json' -w '%{http_code}' -H 'X-Requested-With: deepeye-ui' -H 'Origin: https://127.0.0.1' --data '{\"target\":\"http://127.0.0.1:18081\",\"authorized\":true,\"authorizationNote\":\"bounded local acceptance fixture\"}' https://127.0.0.1/api/scans | grep -q '^400$'"
sed -i '/^deepverify:/d' /etc/deepeye/nginx.htpasswd
rm -f -- "$curl_config"
unset verify_password

check 'upstream source commit marker' grep -Fq 'e98a361ee38ec65660ce585ff6789017a2d7a466' /usr/local/lib/deepeye/deepeye-web.py
check 'OpenAI-compatible regression' runuser -u deepeye -- env HOME=/var/lib/deepeye/home PATH=/opt/deepeye/venv/bin:/usr/bin:/bin bash -lc 'cd /opt/deepeye && pytest -q tests/test_openai_compatible_provider.py'
check 'model lock configured' bash -c "grep -Fq 'model: gpt-oss-120b' /etc/deepeye/config.yaml && grep -Fq 'lock_model: true' /etc/deepeye/config.yaml"
while IFS= read -r tool; do
  check "required command: $tool" runuser -u deepeye -- env PATH=/opt/deepeye/venv/bin:/usr/local/bin:/usr/bin:/bin which "$tool"
done < <(jq -r '.commands[]' /usr/local/share/deepeye-required-tools.json)
check 'required Python modules import' runuser -u deepeye -- env HOME=/var/lib/deepeye/home /opt/deepeye/venv/bin/python -c 'import importlib,json; p=json.load(open("/usr/local/share/deepeye-required-tools.json")); [importlib.import_module(name) for name in p["pythonImports"]]'
check 'Deep Eye CLI starts' runuser -u deepeye -- env HOME=/var/lib/deepeye/home /opt/deepeye/venv/bin/python /opt/deepeye/deep_eye.py --version
check 'browser runtime installed' runuser -u deepeye -- env PLAYWRIGHT_BROWSERS_PATH=/opt/deepeye/playwright /opt/deepeye/venv/bin/python -c 'from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-setuid-sandbox"]); print(b.version); b.close(); p.stop()'

fixture="$run_dir/fixture"
mkdir -p "$fixture/www" "$fixture/reports"
printf '<html><title>Deep Eye fixture</title><a href="/about?name=test">about</a></html>\n' > "$fixture/www/index.html"
printf '<html><title>About</title><p>bounded acceptance target</p></html>\n' > "$fixture/www/about"
python3 -m http.server 18081 --bind 127.0.0.1 --directory "$fixture/www" > "$run_dir/fixture-http.log" 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:18081/ >/dev/null && break; sleep 0.2; done

/opt/deepeye/venv/bin/python - "$fixture/acceptance.yaml" "$fixture/reports" "$run_dir/deep-eye.log" <<'PY'
import sys, yaml
source = yaml.safe_load(open('/etc/deepeye/config.yaml', encoding='utf-8'))
source['vulnerability_scanner']['payload_generation']['use_ai'] = False
source['scanner'].update({'default_threads': 2, 'default_depth': 1, 'max_urls': 5, 'enable_recon': False})
source['advanced'].update({'enable_javascript_rendering': False, 'screenshot_enabled': False})
source['templates']['enabled'] = False
source['ai_triage']['enabled'] = False
source['bug_bounty']['enabled'] = False
source['reporting'].update({'output_directory': sys.argv[2], 'formats': ['html', 'json']})
source['logging'].update({'log_file': sys.argv[3]})
source['database']['enabled'] = False
yaml.safe_dump(source, open(sys.argv[1], 'w', encoding='utf-8'), sort_keys=False)
PY
chown -R deepeye:deepeye "$fixture" "$run_dir/deep-eye.log" 2>/dev/null || true
check 'bounded local scanner/report E2E' timeout 300s runuser -u deepeye -- env \
  HOME=/var/lib/deepeye/home PATH=/opt/deepeye/venv/bin:/usr/local/bin:/usr/bin:/bin \
  /opt/deepeye/venv/bin/python /opt/deepeye/deep_eye.py --no-banner \
  --config "$fixture/acceptance.yaml" --url http://127.0.0.1:18081 --formats html,json
check 'HTML and JSON reports generated' bash -c "find '$fixture/reports' -type f -name '*.html' | grep -q . && find '$fixture/reports' -type f -name '*.json' | grep -q ."
check 'report references bounded target' bash -c "grep -Rqs '127.0.0.1:18081' '$fixture/reports'"

if (( live_llm )); then
  check 'gpt-oss-120b model available' bash -c "curl -fsS http://127.0.0.1:18080/v1/models > '$run_dir/models.json' && jq -e 'any(.data[]?; .id == \"gpt-oss-120b\")' '$run_dir/models.json' >/dev/null"
  check 'Deep Eye OpenAI provider live response' timeout 360s runuser -u deepeye -- env HOME=/var/lib/deepeye/home PATH=/opt/deepeye/venv/bin:/usr/bin:/bin \
    PYTHONPATH=/opt/deepeye /opt/deepeye/venv/bin/python -c "import yaml; from ai_providers.openai_provider import OpenAIProvider; c=yaml.safe_load(open('/etc/deepeye/config.yaml'))['ai_providers']['openai']; r=OpenAIProvider(c).generate('Reply with exactly DEEPEYE_LLM_OK', max_tokens=64); assert 'DEEPEYE_LLM_OK' in r; print(r)"
fi

if (( stability )); then
  state_hash_before="$(sha256sum /var/lib/deepeye/state/jobs.json 2>/dev/null | cut -d' ' -f1 || true)"
  restarts_before="$(systemctl show -p NRestarts --value deepeye.service)"
  systemctl restart deepeye.service
  for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:3333/api/health >/dev/null 2>&1 && break; sleep 1; done
  check 'state remains readable after restart' jq -e '.schema == 1 and (.jobs | type == "object")' /var/lib/deepeye/state/jobs.json
  state_hash_after="$(sha256sum /var/lib/deepeye/state/jobs.json | cut -d' ' -f1)"
  if [[ -z "$state_hash_before" || "$state_hash_before" == "$state_hash_after" ]]; then
    pass 'job ledger stable across restart'
  else
    fail 'job ledger changed unexpectedly across restart'
  fi
  seq 1 1000 | xargs -P10 -n1 sh -c 'curl -fsS --max-time 10 http://127.0.0.1:3333/api/health -o /dev/null' _
  restarts_after="$(systemctl show -p NRestarts --value deepeye.service)"
  if [[ "$restarts_before" == "$restarts_after" ]]; then
    pass '1000-request stability/no restarts'
  else
    fail 'service restarted during stability test'
  fi
  check 'no OOM in current boot' bash -c "! journalctl -b -k --no-pager | grep -qi 'out of memory'"
fi

os_pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
cat > "$report" <<EOF
# Deep Eye acceptance report

- Run: \`$timestamp\`
- Source commit: \`e98a361ee38ec65660ce585ff6789017a2d7a466\`
- Model lock: \`gpt-oss-120b\`
- OS: \`$os_pretty\`
- Evidence directory: \`$run_dir\`

## Evidence

| File | SHA-256 |
|---|---|
EOF
while IFS= read -r -d '' evidence_file; do
  printf "| \`%s\` | \`%s\` |\n" "${evidence_file#"$run_dir"/}" "$(sha256sum "$evidence_file" | cut -d' ' -f1)" >> "$report"
done < <(find "$run_dir" -type f ! -name verify.log -print0 | sort -z)
checksums_tmp="$(mktemp)"
(cd "$run_dir" && find . -type f ! -name verify.log ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$checksums_tmp")
install -m 0640 -o deepeye -g deepeye "$checksums_tmp" "$run_dir/SHA256SUMS"
rm -f "$checksums_tmp"
echo "Evidence: $run_dir"
echo "Report: $report"
(( failures == 0 )) || { echo "$failures acceptance checks failed" >&2; exit 1; }
echo 'All selected Deep Eye acceptance checks passed.'
