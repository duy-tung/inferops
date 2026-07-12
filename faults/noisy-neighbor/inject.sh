#!/usr/bin/env bash
# Noisy-neighbor observation run (IO-T007 extra). Tenant A (default tier,
# low priority) floods the main gateway; tenant B (gold tier, high
# priority) sends a light steady trickle throughout. Observes tier
# isolation at the ops level -- does not tune the fairness logic (infergate's).
set -uo pipefail
FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFEROPS_ROOT="$(cd "$FAULTS_DIR/.." && pwd)"
GW="http://127.0.0.1:8080"
FIXTURES="/home/user/serving-contracts/examples/api"
OUT_DIR="${OUT_DIR:-$FAULTS_DIR/noisy-neighbor/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"
log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

API_KEY_A=$(cat "$INFEROPS_ROOT/compose/secrets/smoke_api_key.txt")
API_KEY_B_FILE="${API_KEY_B_FILE:-/tmp/claude-0/-home-user-ai-infra/f9d2a869-bab7-54d8-a091-357b56be5c68/scratchpad/tenant-b-key.txt}"
if [[ ! -f "$API_KEY_B_FILE" ]]; then
  echo "tenant B API key file not found at $API_KEY_B_FILE -- see hypothesis.md setup step" >&2
  exit 1
fi
API_KEY_B=$(cat "$API_KEY_B_FILE")

log "== Noisy-neighbor observation run — $(date -u --iso-8601=seconds) =="

: > "$OUT_DIR/tenant-a.csv"
: > "$OUT_DIR/tenant-b.csv"
echo "unix_ts,http_code,wall_seconds" >> "$OUT_DIR/tenant-a.csv"
echo "unix_ts,http_code,wall_seconds" >> "$OUT_DIR/tenant-b.csv"

log "-- launching tenant A: 200 concurrent requests (default tier, low priority, > global-inflight-budget=128) --"
for i in $(seq 1 200); do
  (
    t0=$(date +%s.%N)
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY_A" -H "Content-Type: application/json" \
      --data-binary @"$FIXTURES/chat-completion-request.json" 2>/dev/null)
    t1=$(date +%s.%N)
    wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
    echo "$(date +%s.%N),${code:-000},$wall" >> "$OUT_DIR/tenant-a.csv"
  ) &
done
TENANT_A_GROUP_PID=$!

log "-- tenant B: 10 sequential requests (gold tier, high priority) throughout the same window --"
sleep 0.3
for i in $(seq 1 10); do
  t0=$(date +%s.%N)
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY_B" -H "Content-Type: application/json" \
    --data-binary @"$FIXTURES/chat-completion-request.json" 2>/dev/null)
  t1=$(date +%s.%N)
  wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
  echo "$(date +%s.%N),${code:-000},$wall" >> "$OUT_DIR/tenant-b.csv"
  sleep 0.3
done

log "-- waiting for tenant A's flood to finish --"
wait

log ""
log "-- results --"
python3 -c "
import csv
def summarize(path, label):
    rows = list(csv.DictReader(open(path)))
    codes = {}
    walls = []
    for r in rows:
        codes[r['http_code']] = codes.get(r['http_code'], 0) + 1
        walls.append(float(r['wall_seconds']))
    walls.sort()
    n = len(walls)
    p50 = walls[n//2] if n else 0
    p95 = walls[int(n*0.95)-1] if n>1 else (walls[0] if n else 0)
    print(f'{label}: n={n} codes={codes} wall p50={p50:.3f}s p95={p95:.3f}s max={max(walls) if walls else 0:.3f}s')
summarize('$OUT_DIR/tenant-a.csv', 'tenant A (default, 200 concurrent, the noisy one)')
summarize('$OUT_DIR/tenant-b.csv', 'tenant B (gold, 10 sequential trickle)')
" | tee -a "$OUT_DIR/transcript.log"

log ""
log "-- gateway per-tier queue metrics (Contract 2 tenant_tier label) --"
docker exec inferops-gateway wget -qO- http://127.0.0.1:8080/metrics 2>/dev/null | \
  grep -E '^inference_(queue_depth|queue_wait_seconds_(count|sum)|sheds_total)' | tee -a "$OUT_DIR/transcript.log"

log ""
log "Evidence directory: $OUT_DIR"
