#!/usr/bin/env bash
# Fetch and summarise the newest BlueBuild run for caelestia-fedora.
#
# Uses the fine-grained PAT stored outside the repo. The token is never
# written into the working tree or committed.
set -euo pipefail

TOKEN_FILE="${CAELESTIA_AGENT_TOKEN_FILE:-$HOME/.config/caelestia-agent/token}"
REPO="${CAELESTIA_REPO:-lovel33t/caelestia-fedora}"
API="https://api.github.com/repos/$REPO/actions"

[ -r "$TOKEN_FILE" ] || { echo "no token at $TOKEN_FILE" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

run_json() {
  curl -sf -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$1"
}

echo "== runs =="
run_json "$API/runs?per_page=5" > /tmp/opencode/ci-runs.json
python3 - <<'PY'
import json, datetime
for r in json.load(open('/tmp/opencode/ci-runs.json'))['workflow_runs']:
    c = datetime.datetime.fromisoformat(r['created_at'].replace('Z', '+00:00'))
    u = datetime.datetime.fromisoformat(r['updated_at'].replace('Z', '+00:00'))
    print("  {}  {}  {:11} {:9} dur={}".format(
        r['id'], r['head_sha'][:7], r['status'], str(r['conclusion']), str(u - c)[:7]))
PY

RUN_ID="${1:-$(python3 -c "import json;print(json.load(open('/tmp/opencode/ci-runs.json'))['workflow_runs'][0]['id'])")}"

echo
echo "== jobs for $RUN_ID =="
run_json "$API/runs/$RUN_ID/jobs" > /tmp/opencode/ci-jobs.json
python3 - <<'PY'
import json
for j in json.load(open('/tmp/opencode/ci-jobs.json')).get('jobs', []):
    print("  JOB {} -> {}".format(j['name'], j['conclusion']))
    for s in j.get('steps', []):
        print("      {:>2} {:46} {}".format(s['number'], s['name'][:44], s['conclusion']))
PY

LOG="$(mktemp /tmp/opencode/ci-log-XXXXXX.zip)"
if curl -sf -L -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$API/runs/$RUN_ID/logs" -o "$LOG"; then
  echo
  echo "== errors in log =="
  unzip -p "$LOG" 2>/dev/null \
    | grep -aiE "CMake Error|error:|No match for argument|not in gzip|!!!|Failed to run snippet" \
    | sed 's/^.*=> //' | sort -u | head -25 || true
  rm -f "$LOG"
else
  echo "(logs not available yet)"
fi
