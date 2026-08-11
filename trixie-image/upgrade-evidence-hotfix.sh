#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root inside the T3MP3ST container.' >&2; exit 2; }
[[ -f /etc/os-release ]] || { echo 'Unsupported system.' >&2; exit 2; }
. /etc/os-release
[[ ${VERSION_ID:-} == 13 ]] || { echo 'This hotfix requires Debian 13.' >&2; exit 2; }
[[ -d /opt/t3mp3st && -f /etc/t3mp3st/t3mp3st.env ]] || { echo 'T3MP3ST installation not found.' >&2; exit 2; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bundle="${1:-$script_dir/t3mp3st-evidence-hotfix-debian13-amd64.tar.gz}"
checksums="${2:-$script_dir/SHA256SUMS}"
[[ -f "$bundle" && -f "$checksums" ]] || { echo 'Usage: upgrade-evidence-hotfix.sh HOTFIX.tar.gz SHA256SUMS' >&2; exit 2; }

bundle_name="$(basename -- "$bundle")"
expected="$(awk -v name="$bundle_name" '$2 == name || $2 == "*" name { print $1; exit }' "$checksums")"
actual="$(sha256sum "$bundle" | cut -d' ' -f1)"
[[ "$expected" =~ ^[a-f0-9]{64}$ && "$actual" == "$expected" ]] || { echo 'Hotfix checksum mismatch.' >&2; exit 3; }

while IFS= read -r member; do
  [[ -n "$member" && "$member" != /* && "$member" != *'../'* && "$member" != '..' ]] || { echo "Unsafe archive member: $member" >&2; exit 3; }
  [[ "$member" == dist/* || "$member" == docs/* ]] || { echo "Unexpected archive member: $member" >&2; exit 3; }
done < <(tar -tzf "$bundle")

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="/var/lib/t3mp3st/upgrades/evidence-$timestamp"
install -d -m 0700 -o root -g root "$backup_dir"

# Preserve every currently reachable in-memory surface before the first restart.
curl -fsS http://127.0.0.1:3333/api/learning/status > "$backup_dir/learning-status.before.json" || true
curl -fsS http://127.0.0.1:3333/api/mission/status > "$backup_dir/mission-status.before.json" || true
curl -fsS http://127.0.0.1:3333/api/mission/findings > "$backup_dir/mission-findings.before.json" || printf '{"findings":[]}\n' > "$backup_dir/mission-findings.before.json"
curl -fsS http://127.0.0.1:3333/api/mission/report > "$backup_dir/mission-report.before.json" || true
curl -fsS http://127.0.0.1:3333/api/evidence > "$backup_dir/evidence.before.json" || true
curl -fsS http://127.0.0.1:3333/api/findings > "$backup_dir/findings.before.json" || true
cp -a /etc/t3mp3st/t3mp3st.env "$backup_dir/t3mp3st.env.before"
cp -a /usr/local/sbin/t3mp3st-verify "$backup_dir/t3mp3st-verify.before" 2>/dev/null || true
tar -C /opt/t3mp3st -czf "$backup_dir/application.before.tar.gz" dist docs

staging="$(mktemp -d -p /opt t3mp3st-evidence-hotfix.XXXXXXXX)"
tar -xzf "$bundle" -C "$staging"
node --check "$staging/dist/server.js"
[[ -s "$staging/docs/index.html" ]] || { echo 'Hotfix UI is missing.' >&2; exit 3; }

env_file=/etc/t3mp3st/t3mp3st.env
grep -q '^T3MP3ST_STATE_DIR=' "$env_file" || printf 'T3MP3ST_STATE_DIR=/var/lib/t3mp3st/state\n' >> "$env_file"
install -d -m 0750 -o t3mp3st -g t3mp3st \
  /var/lib/t3mp3st/state /var/lib/t3mp3st/evidence /var/lib/t3mp3st/reports

old_dist="/opt/t3mp3st/dist.pre-evidence-$timestamp"
old_docs="/opt/t3mp3st/docs.pre-evidence-$timestamp"
rollback() {
  echo 'Evidence hotfix validation failed; restoring previous application.' >&2
  systemctl stop t3mp3st.service >/dev/null 2>&1 || true
  [[ ! -e /opt/t3mp3st/dist ]] || mv /opt/t3mp3st/dist "/opt/t3mp3st/dist.failed-$timestamp"
  [[ ! -e /opt/t3mp3st/docs ]] || mv /opt/t3mp3st/docs "/opt/t3mp3st/docs.failed-$timestamp"
  [[ ! -e "$old_dist" ]] || mv "$old_dist" /opt/t3mp3st/dist
  [[ ! -e "$old_docs" ]] || mv "$old_docs" /opt/t3mp3st/docs
  cp -a "$backup_dir/t3mp3st.env.before" "$env_file"
  [[ ! -f "$backup_dir/t3mp3st-verify.before" ]] || install -m 0755 "$backup_dir/t3mp3st-verify.before" /usr/local/sbin/t3mp3st-verify
  systemctl start t3mp3st.service >/dev/null 2>&1 || true
}
trap rollback ERR

systemctl stop t3mp3st.service
mv /opt/t3mp3st/dist "$old_dist"
mv /opt/t3mp3st/docs "$old_docs"
mv "$staging/dist" /opt/t3mp3st/dist
mv "$staging/docs" /opt/t3mp3st/docs
chown -R root:root /opt/t3mp3st/dist /opt/t3mp3st/docs
if [[ -f "$script_dir/t3mp3st-verify.sh" ]]; then
  install -m 0755 "$script_dir/t3mp3st-verify.sh" /usr/local/sbin/t3mp3st-verify
fi
systemctl start t3mp3st.service
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:3333/api/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:3333/api/health >/dev/null

# Import evidence that existed only in the old process memory into the new
# persistent canonical ledger. The backup remains root-only regardless.
node --input-type=module - "$backup_dir/mission-findings.before.json" "migrated-$timestamp" <<'NODE'
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [file, missionId] = process.argv.slice(2);
let payload = { findings: [] };
try { payload = JSON.parse(readFileSync(file, 'utf8')); } catch {}
const findings = Array.isArray(payload) ? payload : Array.isArray(payload.findings) ? payload.findings : [];
const post = async (path, body) => {
  const response = await fetch(`http://127.0.0.1:3333${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  if (response.status === 409) return null;
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status} ${await response.text()}`);
  return response.json();
};
const evidenceType = value => ({ request: 'log', response: 'log', output: 'log', file: 'artifact' }[value] || value || 'note');

for (const finding of findings) {
  const sourceId = String(finding.id || finding.title || 'finding');
  const findingId = `migrated-${createHash('sha256').update(`${missionId}\0${sourceId}`).digest('hex').slice(0, 20)}`;
  const evidenceIds = [];
  const evidence = Array.isArray(finding.evidence) ? finding.evidence : finding.evidence ? [finding.evidence] : [];
  for (const [index, item] of evidence.entries()) {
    const record = typeof item === 'string' ? { type: 'artifact', content: item } : (item || {});
    const content = String(record.content || record.summary || record.output || '');
    const id = `migrated-${createHash('sha256').update(`${findingId}\0${index}\0${content}`).digest('hex').slice(0, 20)}`;
    await post('/api/evidence', {
      id, missionId, findingId, type: evidenceType(record.type), title: `${finding.title || 'Finding'} evidence ${index + 1}`,
      summary: content.slice(0, 4000), content, source: 'tool', provenanceStrength: 'tool',
      path: record.path || record.metadata?.path, uri: record.uri || record.metadata?.uri,
      command: record.command || record.metadata?.command,
    });
    evidenceIds.push(id);
  }
  await post('/api/findings', {
    id: findingId, missionId, family: 'web_api', title: finding.title || 'Migrated finding',
    target: finding.targetId || finding.target || 'unknown', claim: finding.description || finding.detail || finding.title || '',
    impact: finding.impact || '', severity: finding.severity || 'info', confidence: evidenceIds.length ? 0.9 : 0.5,
    status: evidenceIds.length ? 'verified' : 'open', evidenceIds, recommendedFix: finding.remediation || '',
  });
}
NODE

learning="$(curl -fsS http://127.0.0.1:3333/api/learning/status)"
jq -e '.policy.persistence == "filesystem" and .policy.stateRoot == "/var/lib/t3mp3st/state"' <<<"$learning" >/dev/null

fixture_mission="hotfix-$timestamp"
fixture_evidence="EV-HOTFIX-$timestamp"
fixture_finding="FINDING-HOTFIX-$timestamp"
fixture_content='HTTP/1.1 200 OK
X-T3MP3ST-Evidence-Hotfix: pass'
fixture_sha="$(printf '%s' "$fixture_content" | sha256sum | cut -d' ' -f1)"
jq -n --arg id "$fixture_evidence" --arg mission "$fixture_mission" --arg content "$fixture_content" \
  '{id:$id,missionId:$mission,type:"log",title:"Hotfix acceptance evidence",summary:"Local fixture",content:$content,source:"tool",provenanceStrength:"tool"}' \
  | curl -fsS http://127.0.0.1:3333/api/evidence -H 'content-type: application/json' --data-binary @- > "$backup_dir/hotfix-evidence.json"
jq -e --arg sha "$fixture_sha" '.sha256 == $sha and (.path | type == "string")' "$backup_dir/hotfix-evidence.json" >/dev/null
jq -n --arg id "$fixture_finding" --arg mission "$fixture_mission" --arg evidence "$fixture_evidence" \
  '{id:$id,missionId:$mission,title:"Hotfix acceptance finding",target:"127.0.0.1",claim:"Canonical evidence survives restart.",severity:"low",confidence:1,status:"verified",evidenceIds:[$evidence],recommendedFix:"Acceptance fixture only."}' \
  | curl -fsS http://127.0.0.1:3333/api/findings -H 'content-type: application/json' --data-binary @- > "$backup_dir/hotfix-finding.json"
curl -fsS "http://127.0.0.1:3333/api/mission/$fixture_mission/report" > "$backup_dir/hotfix-report.before-restart.json"
jq -e --arg id "$fixture_evidence" --arg sha "$fixture_sha" '.report | contains($id) and contains($sha)' "$backup_dir/hotfix-report.before-restart.json" >/dev/null

sleep 2
systemctl restart t3mp3st.service
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:3333/api/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:3333/api/evidence?missionId=$fixture_mission" > "$backup_dir/hotfix-evidence.after-restart.json"
jq -e --arg id "$fixture_evidence" --arg sha "$fixture_sha" 'any(.evidence[]?; .id == $id and .sha256 == $sha)' "$backup_dir/hotfix-evidence.after-restart.json" >/dev/null
curl -fsS "http://127.0.0.1:3333/api/mission/$fixture_mission/report" > "$backup_dir/hotfix-report.after-restart.json"
jq -e --arg id "$fixture_evidence" --arg sha "$fixture_sha" '.report | contains($id) and contains($sha)' "$backup_dir/hotfix-report.after-restart.json" >/dev/null

trap - ERR
echo "Evidence hotfix installed and restart persistence verified."
echo "Backup: $backup_dir"
echo "Application rollback: $old_dist and $old_docs"
