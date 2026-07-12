#!/usr/bin/env bash
# Scenario 03 — slow backend (reduced form: single-backend deployment, see hypothesis.md).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-03/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 03 — slow backend — $(date -u --iso-8601=seconds) =="

flog ""
flog "== Part A: moderate slow (ttft=1500ms), generous budget (ttft-timeout=4s) =="
start_mock mock-faults -ttft=1500ms -itl=20ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults -ttft-timeout=4s -upstream-timeout=30s
wait_ready "http://127.0.0.1:8091/readyz" 30

flog "-- issuing 8 sequential non-stream requests, timing each --"
: > "$OUT_DIR/part-a-timings.csv"
echo "n,http_code,wall_seconds" >> "$OUT_DIR/part-a-timings.csv"
for i in $(seq 1 8); do
  t0=$(date +%s.%N)
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:8091/v1/chat/completions" \
    -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
  t1=$(date +%s.%N)
  wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
  echo "$i,$code,$wall" >> "$OUT_DIR/part-a-timings.csv"
done
cat "$OUT_DIR/part-a-timings.csv" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- inference_backend_healthy after Part A (must still read 1 — slow, not dead) --"
gw_metrics gateway-faults | grep '^inference_backend_healthy' | tee -a "$OUT_DIR/transcript.log"
PART_A_METRICS=$(gw_metrics gateway-faults)
echo "$PART_A_METRICS" > "$OUT_DIR/part-a-metrics.txt"

flog ""
flog "== Part B: severe slow (ttft=3000ms), tight budget (ttft-timeout=1500ms) =="
stop_gateway gateway-faults
start_gateway gateway-faults 8091 mock-faults -ttft-timeout=1500ms -upstream-timeout=30s
wait_ready "http://127.0.0.1:8091/readyz" 30
start_mock mock-faults -ttft=3000ms -itl=20ms -error-rate=0
sleep 1

flog "-- issuing 8 sequential non-stream requests, expecting typed upstream_timeout --"
: > "$OUT_DIR/part-b-timings.csv"
echo "n,http_code,wall_seconds,body" >> "$OUT_DIR/part-b-timings.csv"
for i in $(seq 1 8); do
  t0=$(date +%s.%N)
  resp=$(curl -s -w '\n%{http_code}' -m 10 -X POST "http://127.0.0.1:8091/v1/chat/completions" \
    -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
  t1=$(date +%s.%N)
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -n -1 | tr -d '\n' | tr ',' ';')
  wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
  echo "$i,$code,$wall,\"$body\"" >> "$OUT_DIR/part-b-timings.csv"
done
cat "$OUT_DIR/part-b-timings.csv" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- inference_backend_healthy after Part B (must still read 1 — slow, not dead) --"
gw_metrics gateway-faults | grep '^inference_backend_healthy' | tee -a "$OUT_DIR/transcript.log"
PART_B_METRICS=$(gw_metrics gateway-faults)
echo "$PART_B_METRICS" > "$OUT_DIR/part-b-metrics.txt"
flog "-- requests_total / sheds_total after Part B --"
echo "$PART_B_METRICS" | grep -E '^inference_(requests_total|sheds_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
