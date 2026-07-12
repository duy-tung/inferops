#!/usr/bin/env bash
# IO-T010: config rollout under traffic — the in-cluster-analog of fault
# scenario 8 ("config reload during traffic: snapshot swap, zero dropped
# streams") exercised against the gateway's own IG-T004/ADR-0002
# snapshot/drain machinery: `config.Store.Reload()` builds a brand-new
# immutable Snapshot from the on-disk JSON and atomically swaps a pointer
# (`atomic.Pointer[Snapshot]`) — in-flight requests keep running against
# whichever Snapshot (and whichever backend.ChatBackend instance) they
# captured when dispatched; only requests arriving AFTER the swap see the
# new one. This script proves that property empirically rather than taking
# the source comment's word for it.
#
# Uses compose/docker-compose.llamacpp.yml's gateway-llamacpp
# (-auth-mode=none -config=<file>) — the ONE gateway instance in this repo
# actually running in reloadable-config mode (docs/implementation-notes.md
# IO-T005 entry: the -auth-mode=db `gateway` service's -config is "ignored
# under -auth-mode=db" per the release's own documented behavior, so it
# cannot demonstrate this mechanic).
#
# Rollout change under test: add a second model alias
# ("qwen2.5-1.5b-instruct-v2") to the `models` list — observable (new
# /v1/models entry, new alias accepted in requests) without disturbing the
# alias the background load already depends on, so a clean "zero drops"
# measurement isolates the reload event from an unrelated alias-breakage
# confound. Rollback reverts to the original file content and reloads
# again, restoring the pre-rollout state.
#
# Honesty note (write results as measured, per program evidence rules): if
# ANY request fails during either reload, this script reports the real
# count — it does not retry silently or omit the failure.
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
GATEWAY="http://127.0.0.1:8082"
CONFIG_FILE="$COMPOSE_DIR/llama-cpp/gateway-config.json"
FIXTURES="$(cd "$(dirname "$0")/../compose/llama-cpp/fixtures" && pwd)"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/config-rollout-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

log "== inferops IO-T010 config-rollout-under-traffic test — $(date -u --iso-8601=seconds) =="

log "-- ensuring llama-cpp + gateway-llamacpp are up --"
( cd "$COMPOSE_DIR" && export COMPOSE_FILE="docker-compose.yml:docker-compose.llamacpp.yml" && \
  docker compose --profile llamacpp up -d llama-cpp gateway-llamacpp ) >>"$OUT_DIR/transcript.log" 2>&1
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$GATEWAY/readyz" 2>/dev/null)
  [[ "$code" == "200" ]] && break
  sleep 1
done
log "gateway-llamacpp /readyz: ${code:-never became ready}"

ORIGINAL_CONFIG="$(cat "$CONFIG_FILE")"
cp "$CONFIG_FILE" "$OUT_DIR/gateway-config.before.json"
restore_original() {
  # Direct overwrite of the SAME inode (bash `>` redirection: open
  # O_WRONLY|O_TRUNC on the existing path), not `mv` of a different file
  # onto it — a docker bind mount of a single file tracks the mounted
  # inode, so a rename-replace at the host path would NOT be visible
  # inside the container (the classic ConfigMap-subPath gotcha; k8s itself
  # works around this with an atomic symlink-swap at the directory level).
  # Writing in place to the same inode sidesteps that entirely and is what
  # this script relies on for the container to see the new content at all.
  printf '%s' "$ORIGINAL_CONFIG" > "$CONFIG_FILE"
}
trap restore_original EXIT

SHORT_LOG="$OUT_DIR/short-requests.csv"
STREAM_LOG="$OUT_DIR/stream-requests.csv"
echo "unix_ts,http_code,model" > "$SHORT_LOG"
echo "unix_ts,http_code,done_sentinel_seen" > "$STREAM_LOG"
STOP_FLAG="$OUT_DIR/.stop"
rm -f "$STOP_FLAG"

log ""
log "-- starting background load: short completions (~every 400ms) + streams (~every 3s), model=qwen2.5-1.5b-instruct --"
(
  while [[ ! -f "$STOP_FLAG" ]]; do
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
      -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
    echo "$(date +%s.%N),$code,qwen2.5-1.5b-instruct" >> "$SHORT_LOG"
    sleep 0.4
  done
) &
SHORT_PID=$!

(
  while [[ ! -f "$STOP_FLAG" ]]; do
    resp=$(curl -s -m 20 -X POST "$GATEWAY/v1/chat/completions" \
      -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request-stream.json")
    code=200
    [[ -z "$resp" ]] && code=000
    done_seen=0
    grep -q '^data: \[DONE\]$' <<<"$resp" && done_seen=1
    echo "$(date +%s.%N),$code,$done_seen" >> "$STREAM_LOG"
    sleep 3
  done
) &
STREAM_PID=$!

sleep 3
log "background load running (short pid=$SHORT_PID, stream pid=$STREAM_PID); baseline established"

log ""
log "-- BEFORE: current config_version (from gateway logs) --"
BEFORE_VERSION=$(docker logs inferops-gateway-llamacpp 2>&1 | grep -o 'config_version=[^ ]*' | tail -1)
log "  $BEFORE_VERSION"

log ""
log "-- ROLLOUT: writing new config (adds model alias qwen2.5-1.5b-instruct-v2) --"
python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
if 'qwen2.5-1.5b-instruct-v2' not in cfg['models']:
    cfg['models'].append('qwen2.5-1.5b-instruct-v2')
open('$CONFIG_FILE', 'w').write(json.dumps(cfg, indent=2) + '\n')
"
cp "$CONFIG_FILE" "$OUT_DIR/gateway-config.after-rollout.json"
cat "$CONFIG_FILE" >> "$OUT_DIR/transcript.log"

log "-- triggering reload via the admin endpoint (in-cluster only, docs/security.md §4) --"
RELOAD_RESP=$(docker exec inferops-gateway-llamacpp wget -q -O - --post-data='' http://127.0.0.1:8090/admin/v1/config/reload)
log "  admin response: $RELOAD_RESP"
AFTER_VERSION=$(python3 -c "import json,sys; print(json.loads('''$RELOAD_RESP''')['config_version'])" 2>/dev/null || echo "PARSE_ERROR")
log "  new config_version: $AFTER_VERSION"

sleep 3
log ""
log "-- verifying the new snapshot is actually live --"
MODELS_RESP=$(curl -s "$GATEWAY/v1/models")
echo "$MODELS_RESP" > "$OUT_DIR/models-after-rollout.json"
if grep -q 'qwen2.5-1.5b-instruct-v2' <<<"$MODELS_RESP"; then
  log "PASS  new model alias qwen2.5-1.5b-instruct-v2 appears in /v1/models"
else
  log "FAIL  new model alias qwen2.5-1.5b-instruct-v2 missing from /v1/models"
fi
NEW_ALIAS_CODE=$(curl -s -o "$OUT_DIR/new-alias-request.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"qwen2.5-1.5b-instruct-v2","messages":[{"role":"user","content":"ping"}],"max_completion_tokens":5,"temperature":0}')
log "  request against the NEW alias: HTTP $NEW_ALIAS_CODE"

sleep 3
log ""
log "-- ROLLBACK: restoring original config (removes the v2 alias) --"
restore_original
cp "$CONFIG_FILE" "$OUT_DIR/gateway-config.after-rollback.json"

ROLLBACK_RESP=$(docker exec inferops-gateway-llamacpp wget -q -O - --post-data='' http://127.0.0.1:8090/admin/v1/config/reload)
log "  admin response: $ROLLBACK_RESP"
ROLLBACK_VERSION=$(python3 -c "import json,sys; print(json.loads('''$ROLLBACK_RESP''')['config_version'])" 2>/dev/null || echo "PARSE_ERROR")
log "  rolled-back config_version: $ROLLBACK_VERSION"

sleep 3
MODELS_AFTER_ROLLBACK=$(curl -s "$GATEWAY/v1/models")
echo "$MODELS_AFTER_ROLLBACK" > "$OUT_DIR/models-after-rollback.json"
if grep -q 'qwen2.5-1.5b-instruct-v2' <<<"$MODELS_AFTER_ROLLBACK"; then
  log "FAIL  v2 alias still present after rollback"
else
  log "PASS  v2 alias absent after rollback (original state restored)"
fi

log ""
log "-- stopping background load --"
touch "$STOP_FLAG"
wait "$SHORT_PID" "$STREAM_PID" 2>/dev/null

log ""
log "== RESULTS =="
SHORT_TOTAL=$(($(wc -l < "$SHORT_LOG") - 1))
SHORT_FAIL=$(awk -F, 'NR>1 && $2!="200"' "$SHORT_LOG" | wc -l)
STREAM_TOTAL=$(($(wc -l < "$STREAM_LOG") - 1))
STREAM_FAIL=$(awk -F, 'NR>1 && ($2!="200" || $3!="1")' "$STREAM_LOG" | wc -l)
log "short requests:  $SHORT_TOTAL total, $SHORT_FAIL failed/dropped"
log "stream requests: $STREAM_TOTAL total, $STREAM_FAIL failed/dropped (non-200 or missing [DONE])"
if [[ "$SHORT_FAIL" -gt 0 || "$STREAM_FAIL" -gt 0 ]]; then
  log "-- non-passing rows (short) --"
  awk -F, 'NR>1 && $2!="200"' "$SHORT_LOG" | tee -a "$OUT_DIR/transcript.log"
  log "-- non-passing rows (stream) --"
  awk -F, 'NR>1 && ($2!="200" || $3!="1")' "$STREAM_LOG" | tee -a "$OUT_DIR/transcript.log"
fi
log "config_version: before=$BEFORE_VERSION -> after-rollout=$AFTER_VERSION -> after-rollback=$ROLLBACK_VERSION"
log "Evidence directory: $OUT_DIR"

TOTAL_FAIL=$((SHORT_FAIL + STREAM_FAIL))
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
  log "VERDICT: PASS — zero dropped streams across both the rollout and the rollback"
  exit 0
else
  log "VERDICT: FAIL — $TOTAL_FAIL dropped/failed requests observed (reported honestly, not hidden)"
  exit 1
fi
