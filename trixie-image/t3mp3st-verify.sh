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
run_dir="/var/lib/t3mp3st/evidence/acceptance-$timestamp"
report="/var/lib/t3mp3st/reports/acceptance-$timestamp.md"
install -d -m 0750 -o t3mp3st -g t3mp3st "$run_dir" "$(dirname "$report")"
exec > >(tee "$run_dir/verify.log") 2>&1

failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

echo "T3MP3ST acceptance $timestamp"
check 'Debian 13' grep -q '^VERSION_ID="13"' /etc/os-release
check 'unprivileged-safe app service active' systemctl is-active --quiet t3mp3st.service
check 'relay service active' systemctl is-active --quiet t3mp3st-llm-relay.service
check 'nginx active' systemctl is-active --quiet nginx.service
check 'no failed systemd units' bash -c '[[ "$(systemctl --failed --no-legend | wc -l)" -eq 0 ]]'
check 'backend only on loopback' bash -c "ss -lntH '( sport = :3333 )' | grep -q '127.0.0.1:3333' && ! ss -lntH '( sport = :3333 )' | grep -qE '(0\.0\.0\.0|\[::\]):3333'"
check 'relay only on loopback' bash -c "ss -lntH '( sport = :18080 )' | grep -q '127.0.0.1:18080'"
check 'HTTP redirects to HTTPS' bash -c "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^301$'"
check 'HTTPS rejects unauthenticated access' bash -c "curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1/ | grep -q '^401$'"
check 'nginx configuration' nginx -t
verify_password="$(openssl rand -hex 18)"
printf '%s\n' "$verify_password" | htpasswd -i /etc/t3mp3st/nginx.htpasswd t3verify >/dev/null
curl_config="$(mktemp)"
chmod 0600 "$curl_config"
printf 'insecure\nsilent\nshow-error\nuser = "t3verify:%s"\n' "$verify_password" > "$curl_config"
if curl --config "$curl_config" --fail https://127.0.0.1/api/health -o "$run_dir/nginx-health.json"; then pass 'authenticated nginx proxy/Host header'; else fail 'authenticated nginx proxy/Host header'; fi
if curl --config "$curl_config" --fail -H 'Origin: https://127.0.0.1' -H 'Content-Type: application/json' \
  --data '{"provider":"openai"}' https://127.0.0.1/api/models -o "$run_dir/nginx-models.json" \
  && jq -e '.serverLocked == true and (.models | length > 0)' "$run_dir/nginx-models.json" >/dev/null; then
  pass 'authenticated nginx same-origin POST proxy'
else
  fail 'authenticated nginx same-origin POST proxy'
fi
sed -i '/^t3verify:/d' /etc/t3mp3st/nginx.htpasswd
rm -f -- "$curl_config"
unset verify_password

while IFS= read -r command_name; do
  check "tool on t3mp3st PATH: $command_name" runuser -u t3mp3st -- env HOME=/var/lib/t3mp3st/home sh -c "command -v '$command_name' >/dev/null"
done < <(jq -r '.required[]' /usr/local/share/t3mp3st/required-tools.json)

tool_smoke() {
  local tool=$1 output rc=0
  local -a args
  case "$tool" in
    amass) args=(-version) ;; chromium|curl|feroxbuster|file|git|gobuster|jq|node|npm|osv-scanner|pandoc|python3|semgrep|sqlmap|trivy|trufflehog|wafw00f|whatweb|whois|yara) args=(--version) ;;
    dalfox) args=(version) ;; dig) args=(-v) ;; exiftool) args=(-ver) ;; ffuf) args=(-V) ;;
    gitleaks|grype|openssl|syft) args=(version) ;; host) args=(-V) ;; nikto) args=(-Version) ;;
    dnsx|httpx|katana|naabu|nuclei|subfinder) args=(-version) ;;
    nmap|testssl) args=(--version) ;; pdftotext) args=(-v) ;;
    *) return 1 ;;
  esac
  set +e
  output="$(timeout 30s runuser -u t3mp3st -- env HOME=/var/lib/t3mp3st/home "$tool" "${args[@]}" 2>&1)"; rc=$?
  set -e
  [[ $rc -eq 0 || $rc -eq 1 ]] && [[ "$output" =~ [0-9] ]]
}
while IFS= read -r command_name; do check "executable smoke: $command_name" tool_smoke "$command_name"; done < <(jq -r '.required[]' /usr/local/share/t3mp3st/required-tools.json)

fixture="$run_dir/fixture"
mkdir -p "$fixture/www"
printf '<html><a href="/admin">admin</a></html>\n' > "$fixture/www/index.html"
printf 'secret = "FAKE_TEST_TOKEN_0123456789"\n' > "$fixture/fake-secret.py"
printf 'rule smoke { strings: $a = "FAKE_TEST_TOKEN" condition: $a }\n' > "$fixture/smoke.yar"
cat > "$fixture/semgrep.yaml" <<'EOF'
rules:
  - id: synthetic-secret
    languages: [python]
    severity: WARNING
    message: Synthetic acceptance secret
    pattern: $X = "FAKE_TEST_TOKEN_0123456789"
EOF
python3 -m http.server 18081 --bind 127.0.0.1 --directory "$fixture/www" >"$run_dir/fixture-http.log" 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do curl -fsS http://127.0.0.1:18081/ >/dev/null && break; sleep 0.2; done

check 'nmap local fixture' bash -c "nmap -Pn -p18081 127.0.0.1 -oN '$run_dir/nmap.txt' | grep -q '18081/tcp open'"
check 'httpx local fixture' bash -c "printf 'http://127.0.0.1:18081\n' | httpx -silent -status-code > '$run_dir/httpx.txt' && grep -q '\[200\]' '$run_dir/httpx.txt'"
check 'katana local fixture' bash -c "katana -u http://127.0.0.1:18081 -silent -d 1 > '$run_dir/katana.txt' && grep -q '127.0.0.1' '$run_dir/katana.txt'"
check 'ffuf local fixture' bash -c "printf 'admin\nmissing\n' > '$fixture/words.txt'; ffuf -noninteractive -s -w '$fixture/words.txt' -u http://127.0.0.1:18081/FUZZ > '$run_dir/ffuf.txt'"
check 'nuclei local fixture' bash -c "printf 'id: local-smoke\ninfo:\n  name: local-smoke\n  author: t3mp3st\n  severity: info\nhttp:\n  - method: GET\n    path:\n      - \"{{BaseURL}}/\"\n    matchers:\n      - type: status\n        status: [200]\n' > '$fixture/smoke.yaml'; nuclei -u http://127.0.0.1:18081 -t '$fixture/smoke.yaml' -silent > '$run_dir/nuclei.txt' && grep -q local-smoke '$run_dir/nuclei.txt'"
check 'semgrep synthetic source' bash -c "semgrep scan --quiet --config '$fixture/semgrep.yaml' '$fixture/fake-secret.py' --json > '$run_dir/semgrep.json' && jq -e '.results | length == 1' '$run_dir/semgrep.json' >/dev/null"
check 'gitleaks synthetic source' bash -c "gitleaks detect --no-git --source '$fixture' --report-format json --report-path '$run_dir/gitleaks.json' --exit-code 0"
check 'yara synthetic source' bash -c "yara '$fixture/smoke.yar' '$fixture/fake-secret.py' > '$run_dir/yara.txt' && grep -q smoke '$run_dir/yara.txt'"
check 'syft filesystem SBOM' bash -c "syft 'dir:$fixture' -o cyclonedx-json='$run_dir/sbom.cdx.json' >/dev/null"

evidence_body="$fixture/http-response.txt"
printf 'HTTP/1.1 200 OK\nX-T3MP3ST-Canary: present\nAuthorization: Bearer sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$evidence_body"
evidence_sha="$(sha256sum "$evidence_body" | cut -d' ' -f1)"
ledger_mission_id="acceptance-$timestamp"
ledger_evidence_id="EV-$timestamp"
ledger_finding_id="FINDING-$timestamp"
check 'ledger persistence uses filesystem' bash -c "curl -fsS http://127.0.0.1:3333/api/learning/status > '$run_dir/learning-status.json' && jq -e '.policy.persistence == \"filesystem\" and (.policy.stateFile | type == \"string\")' '$run_dir/learning-status.json' >/dev/null"
jq -n --arg id "$ledger_evidence_id" --arg mission "$ledger_mission_id" --rawfile content "$evidence_body" \
  '{id:$id,missionId:$mission,type:"log",title:"Synthetic acceptance response",summary:"Bounded local evidence fixture.",content:$content,source:"tool",provenanceStrength:"tool"}' \
  > "$run_dir/ledger-evidence-request.json"
check 'canonical evidence ledger capture' bash -c "curl -fsS http://127.0.0.1:3333/api/evidence -H 'content-type: application/json' --data-binary '@$run_dir/ledger-evidence-request.json' > '$run_dir/ledger-evidence-response.json' && jq -e --arg id '$ledger_evidence_id' --arg sha '$evidence_sha' '.id == \$id and .sha256 == \$sha and (.path | type == \"string\") and (.content | contains(\"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\") | not)' '$run_dir/ledger-evidence-response.json' >/dev/null"
jq -n --arg id "$ledger_finding_id" --arg mission "$ledger_mission_id" --arg evidence "$ledger_evidence_id" \
  '{id:$id,missionId:$mission,family:"web_api",title:"Synthetic persisted finding",target:"127.0.0.1",claim:"The bounded canary is present.",impact:"Acceptance fixture only.",severity:"high",confidence:1,status:"verified",evidenceIds:[$evidence],recommendedFix:"Remove the bounded canary.",acceptanceCriteria:["Canary is absent after remediation."]}' \
  > "$run_dir/ledger-finding-request.json"
check 'canonical finding links evidence' bash -c "curl -fsS http://127.0.0.1:3333/api/findings -H 'content-type: application/json' --data-binary '@$run_dir/ledger-finding-request.json' > '$run_dir/ledger-finding-response.json' && jq -e --arg evidence '$ledger_evidence_id' '.evidenceIds | index(\$evidence)' '$run_dir/ledger-finding-response.json' >/dev/null"
check 'mission report resolves persistent evidence' bash -c "curl -fsS 'http://127.0.0.1:3333/api/mission/$ledger_mission_id/report' > '$run_dir/mission-report.json' && jq -e --arg evidence '$ledger_evidence_id' --arg sha '$evidence_sha' '.report | contains(\"## Persistent Evidence Ledger\") and contains(\$evidence) and contains(\$sha) and (contains(\"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\") | not)' '$run_dir/mission-report.json' >/dev/null"
jq -n --slurpfile finding "$run_dir/ledger-finding-response.json" '{platform:"hackerone",programHandle:"local-fixture",finding:$finding[0]}' > "$run_dir/ledger-bounty-request.json"
check 'bounty report resolves canonical ledger evidence' bash -c "curl -fsS http://127.0.0.1:3333/api/bounty/format -H 'content-type: application/json' --data-binary '@$run_dir/ledger-bounty-request.json' > '$run_dir/ledger-bounty-response.json' && jq -e --arg evidence '$ledger_evidence_id' --arg sha '$evidence_sha' '.report.severity == \"high\" and (.report.body | contains(\"## Evidence Appendix\") and contains(\$evidence) and contains(\$sha) and (contains(\"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\") | not))' '$run_dir/ledger-bounty-response.json' >/dev/null"
jq -n --arg sha "$evidence_sha" '{platform:"hackerone",programHandle:"local-fixture",finding:{id:"finding-acceptance-1",title:"Synthetic acceptance finding",severity_self:"low",summary:"Bounded local fixture only.",root_cause:"Synthetic condition.",poc:"Request the local fixture.",impact:"No production impact.",remediation:"Remove the fixture.",evidence:[{id:"EV-HTTP-1",type:"http-response",content:"HTTP/1.1 200 OK\nAuthorization: Bearer sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",path:"evidence/http-response.txt",sha256:$sha}]}}' > "$run_dir/bounty-request.json"
check 'bounty report evidence E2E' bash -c "curl -fsS http://127.0.0.1:3333/api/bounty/format -H 'content-type: application/json' --data-binary '@$run_dir/bounty-request.json' > '$run_dir/bounty-response.json' && jq -e --arg sha '$evidence_sha' '.report.body | contains(\"## Evidence Appendix\") and contains(\"EV-HTTP-1\") and contains(\$sha) and (contains(\"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\") | not)' '$run_dir/bounty-response.json' >/dev/null"

cat > "$report" <<EOF
# T3MP3ST acceptance report

- Run: \`$timestamp\`
- Host: \`$(hostname)\`
- OS: \`$(. /etc/os-release; printf '%s' "$PRETTY_NAME")\`
- Model lock: \`gpt-oss-120b\`
- Evidence directory: \`$run_dir\`

## Evidence

| Evidence ID | File | SHA-256 |
|---|---|---|
EOF
evidence_count=0
while IFS= read -r -d '' evidence_file; do
  evidence_id="E-$(printf '%04d' "$((++evidence_count))")"
  printf '| %s | `%s` | `%s` |\n' "$evidence_id" "${evidence_file#$run_dir/}" "$(sha256sum "$evidence_file" | cut -d' ' -f1)" >> "$report"
done < <(find "$run_dir" -type f ! -name verify.log -print0 | sort -z)
check 'generated reports redact fake secret' bash -c "! grep -qs 'sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' '$report' '$run_dir/bounty-response.json' '$run_dir/ledger-bounty-response.json' '$run_dir/mission-report.json' '$run_dir/ledger-evidence-response.json'"
check 'HTML report render' pandoc "$report" -s -o "${report%.md}.html"
check 'PDF report render' pandoc "$report" --pdf-engine=weasyprint -o "${report%.md}.pdf"

if (( live_llm )); then
  llm_json="$run_dir/gpt-oss-tool-call.json"
  check 'gpt-oss-120b model available' bash -c "curl -fsS http://127.0.0.1:18080/v1/models | jq -e 'any(.data[]?; .id == \"gpt-oss-120b\")' > '$run_dir/models.json'"
  check 'gpt-oss tool call and arguments' bash -c "curl -fsS --max-time 300 http://127.0.0.1:18080/v1/chat/completions -H 'content-type: application/json' -d '{\"model\":\"gpt-oss-120b\",\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Call evidence_hash with value abc. Do not answer directly.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"evidence_hash\",\"description\":\"Hash evidence\",\"parameters\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}}}]}' > '$llm_json' && jq -e '.choices[0].message.tool_calls[0].function.name == \"evidence_hash\"' '$llm_json' >/dev/null"
  continuation_request="$run_dir/gpt-oss-continuation-request.json"
  jq '{model:"gpt-oss-120b",temperature:0,messages:[{role:"user",content:"Call evidence_hash with value abc. Do not answer directly."},.choices[0].message,{role:"tool",tool_call_id:.choices[0].message.tool_calls[0].id,content:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}],tools:[{type:"function",function:{name:"evidence_hash",description:"Hash evidence",parameters:{type:"object",properties:{value:{type:"string"}},required:["value"]}}}]}' "$llm_json" > "$continuation_request"
  check 'gpt-oss reasoning/tool continuation' bash -c "curl -fsS --max-time 300 http://127.0.0.1:18080/v1/chat/completions -H 'content-type: application/json' --data-binary '@$continuation_request' > '$run_dir/gpt-oss-continuation.json' && jq -e '.choices[0].message.content | type == \"string\" and length > 0' '$run_dir/gpt-oss-continuation.json' >/dev/null"
fi

if (( stability )); then
  sleep 2
  systemctl restart t3mp3st.service
  for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:3333/api/health >/dev/null 2>&1 && break; sleep 1; done
  check 'evidence survives service restart' bash -c "curl -fsS 'http://127.0.0.1:3333/api/evidence?missionId=$ledger_mission_id' > '$run_dir/ledger-after-restart.json' && jq -e --arg evidence '$ledger_evidence_id' --arg sha '$evidence_sha' 'any(.evidence[]?; .id == \$evidence and .sha256 == \$sha)' '$run_dir/ledger-after-restart.json' >/dev/null"
  check 'evidence-backed report survives restart' bash -c "curl -fsS 'http://127.0.0.1:3333/api/mission/$ledger_mission_id/report' > '$run_dir/report-after-restart.json' && jq -e --arg evidence '$ledger_evidence_id' --arg sha '$evidence_sha' '.report | contains(\$evidence) and contains(\$sha)' '$run_dir/report-after-restart.json' >/dev/null"
  restarts_before="$(systemctl show -p NRestarts --value t3mp3st.service)"
  seq 1 1000 | xargs -P10 -n1 sh -c 'curl -fsS --max-time 10 http://127.0.0.1:3333/api/health -o /dev/null' _
  restarts_after="$(systemctl show -p NRestarts --value t3mp3st.service)"
  [[ "$restarts_before" == "$restarts_after" ]] && pass '1000-request stability/no restarts' || fail 'service restarted during stability test'
  check 'no OOM in current boot' bash -c "! journalctl -b -k --no-pager | grep -qi 'out of memory'"
fi

(cd "$run_dir" && find . -type f ! -name verify.log ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

echo "Evidence: $run_dir"
echo "Report: $report"
(( failures == 0 )) || { echo "$failures acceptance checks failed" >&2; exit 1; }
echo 'All selected acceptance checks passed.'
