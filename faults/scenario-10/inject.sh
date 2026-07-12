#!/usr/bin/env bash
# Scenario 10 — one unhealthy backend (reduced form: single-backend
# deployment, see hypothesis.md). docker pause freezes the WHOLE process
# (including /healthz), unlike -error-rate used elsewhere in this campaign.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-10/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 10 — one unhealthy backend — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults + gateway-faults (default health-poll/breaker config) --"
start_mock mock-faults -ttft=20ms -itl=8ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults
wait_ready "http://127.0.0.1:8091/readyz" 30

flog "-- BEFORE: inference_backend_healthy --"
gw_metrics gateway-faults | grep '^inference_backend_healthy' | tee -a "$OUT_DIR/transcript.log"

: > "$OUT_DIR/probe.csv"
echo "t_ms,http_code,wall_ms" >> "$OUT_DIR/probe.csv"
T0=$(date +%s.%N)
probe() {
  # Launched as an independent background job so one blocked probe (the
  # backend is fully frozen by docker pause -- a request in flight at that
  # instant hangs until the client's own -m timeout, not a fast failure)
  # never delays the NEXT probe's send time -- otherwise a single blocked
  # request would starve the whole timeline of samples during the pause,
  # which the first attempt at this script did (a sequential loop meant
  # exactly one probe landed inside the entire pause window).
  local t0 code t1
  t0=$(date +%s.%N)
  code=$(curl -s -o /dev/null -m 1.2 -w '%{http_code}' -X POST "http://127.0.0.1:8091/v1/chat/completions" \
    -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json" 2>/dev/null)
  t1=$(date +%s.%N)
  python3 -c "
t0=$T0; now=$t0; t1=$t1
print(f'{(now-t0)*1000:.0f},{\"$code\" or \"000\"},{(t1-now)*1000:.0f}')
" >> "$OUT_DIR/probe.csv"
}

flog ""
flog "-- sending a probe request every ~150ms for ~9s (each in its own background job), pausing mock-faults at t=1.5s --"
(
  for i in $(seq 1 60); do
    probe &
    sleep 0.15
  done
  wait
) &
PROBE_PID=$!

sleep 1.5
PAUSE_AT=$(date -u --iso-8601=seconds)
flog "-- t+1.5s: docker pause inferops-mock-faults (at $PAUSE_AT) --"
docker pause inferops-mock-faults >>"$OUT_DIR/transcript.log" 2>&1

sleep 0.8
flog "-- t+2.3s: inference_backend_healthy after the pause --"
gw_metrics gateway-faults | grep '^inference_backend_healthy' | tee -a "$OUT_DIR/transcript.log"

sleep 2.2
UNPAUSE_AT=$(date -u --iso-8601=seconds)
flog ""
flog "-- t+4.5s: docker unpause inferops-mock-faults (at $UNPAUSE_AT) --"
docker unpause inferops-mock-faults >>"$OUT_DIR/transcript.log" 2>&1

wait "$PROBE_PID"

sleep 1
flog ""
flog "-- AFTER: inference_backend_healthy (expect back to 1) --"
AFTER=$(gw_metrics gateway-faults)
echo "$AFTER" > "$OUT_DIR/gateway-metrics-after.txt"
echo "$AFTER" | grep -E '^inference_(backend_healthy|retries_total|requests_total|sheds_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- probe timeline (t_ms, http_code, wall_ms) --"
cat "$OUT_DIR/probe.csv" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- summary: response codes before pause (t<1500ms), during pause (1500-4500ms), after unpause (t>4500ms) --"
python3 -c "
import csv, collections
rows = list(csv.DictReader(open('$OUT_DIR/probe.csv')))
def bucket(t):
    t = int(t)
    if t < 1500: return 'before'
    if t < 4500: return 'during'
    return 'after'
c = collections.defaultdict(collections.Counter)
for r in rows:
    c[bucket(r['t_ms'])][r['http_code']] += 1
for k in ['before','during','after']:
    print(k, dict(c[k]))
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
