#!/usr/bin/env bash
# Scenario 07 — retry storm.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-07/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 07 — retry storm — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults (-error-rate=0.3) + gateway-faults (admission tightened, default retry budget) --"
start_mock mock-faults -ttft=20ms -itl=8ms -error-rate=0.3
start_gateway gateway-faults 8091 mock-faults \
  -admission-tenant-queue-cap=10 -admission-global-inflight-budget=10
wait_ready "http://127.0.0.1:8091/readyz" 30

BEFORE=$(gw_metrics gateway-faults)
flog "BEFORE retries_total: $(echo "$BEFORE" | grep '^inference_retries_total')"

WORKERS=10
DURATION_S=15
STOP_FLAG="$OUT_DIR/.stop"
rm -f "$STOP_FLAG"
COUNT_DIR="$OUT_DIR/counts"
mkdir -p "$COUNT_DIR"

flog ""
flog "-- launching $WORKERS aggressive no-backoff client workers for ${DURATION_S}s --"
worker() {
  # mockengine's error injection is a DETERMINISTIC hash of the request
  # (internal/mockengine/engine.go: "same config + same request always
  # yields the same value") -- an identical fixture sent repeatedly always
  # gets the SAME pass/fail outcome, never a real 30% rate. Each call here
  # varies the prompt (worker id + counter) so distinct requests sample the
  # configured error rate across the space, as a real client fleet's varied
  # traffic would.
  local id="$1" n=0 ok=0 nonok=0
  while [[ ! -f "$STOP_FLAG" ]]; do
    n=$((n+1))
    body=$(printf '{"model":"mock-8b","messages":[{"role":"user","content":"storm worker %s request %s"}],"max_completion_tokens":20,"temperature":0}' "$id" "$n")
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "http://127.0.0.1:8091/v1/chat/completions" \
      -H "Content-Type: application/json" -d "$body" 2>/dev/null)
    if [[ "$code" == "200" ]]; then ok=$((ok+1)); else nonok=$((nonok+1)); fi
    # deliberately NO sleep / backoff here -- the fault this scenario injects.
  done
  echo "$n,$ok,$nonok" > "$COUNT_DIR/worker-$id.csv"
}
for w in $(seq 1 "$WORKERS"); do
  worker "$w" &
done

sleep "$DURATION_S"
touch "$STOP_FLAG"
wait

flog "-- worker totals (n,ok,nonok) --"
cat "$COUNT_DIR"/worker-*.csv | tee -a "$OUT_DIR/transcript.log"
TOTAL_N=$(awk -F, '{s+=$1} END{print s}' "$COUNT_DIR"/worker-*.csv)
TOTAL_OK=$(awk -F, '{s+=$2} END{print s}' "$COUNT_DIR"/worker-*.csv)
TOTAL_NONOK=$(awk -F, '{s+=$3} END{print s}' "$COUNT_DIR"/worker-*.csv)
flog "TOTAL: requests_issued=$TOTAL_N ok=$TOTAL_OK non_ok=$TOTAL_NONOK"

AFTER=$(gw_metrics gateway-faults)
echo "$AFTER" > "$OUT_DIR/gateway-metrics-after.txt"
flog ""
flog "-- gateway-faults /metrics after the storm --"
echo "$AFTER" | grep -E '^inference_(retries_total|sheds_total|requests_total|backend_healthy)' | tee -a "$OUT_DIR/transcript.log"

RETRIES=$(echo "$AFTER" | grep '^inference_retries_total{stage="pre_first_token"}' | awk '{print $2}')
TOTAL_REQ=$(echo "$AFTER" | grep '^inference_requests_total' | awk '{s+=$2} END{print s}')
flog ""
flog "-- amplification check: retries_total=$RETRIES vs total dispatched/classified requests=$TOTAL_REQ (retry-budget-ratio default = 0.1) --"
python3 -c "
retries = $RETRIES
total = $TOTAL_REQ
ratio = retries/total if total else 0
print(f'retries/total = {ratio:.3f} (budget ratio configured: 0.10)')
print('capped (ratio well under the naive 0.3 error-rate, i.e. NOT one retry per error)' if ratio < 0.2 else 'NOT clearly capped -- investigate')
"

flog ""
flog "== Part 2: tighter admission budget, to also exercise clause 2 (excess client-retry load shed, not forwarded) =="
stop_gateway gateway-faults
start_gateway gateway-faults 8091 mock-faults \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=3
wait_ready "http://127.0.0.1:8091/readyz" 30

rm -f "$STOP_FLAG"
COUNT_DIR2="$OUT_DIR/counts-part2"
mkdir -p "$COUNT_DIR2"
for w in $(seq 1 "$WORKERS"); do
  ( local_id="$w"
    n=0; ok=0; nonok=0
    while [[ ! -f "$STOP_FLAG" ]]; do
      n=$((n+1))
      body=$(printf '{"model":"mock-8b","messages":[{"role":"user","content":"storm2 worker %s request %s"}],"max_completion_tokens":20,"temperature":0}' "$local_id" "$n")
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "http://127.0.0.1:8091/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null)
      if [[ "$code" == "200" ]]; then ok=$((ok+1)); else nonok=$((nonok+1)); fi
    done
    echo "$n,$ok,$nonok" > "$COUNT_DIR2/worker-$local_id.csv"
  ) &
done
sleep "$DURATION_S"
touch "$STOP_FLAG"
wait

TOTAL_N2=$(awk -F, '{s+=$1} END{print s}' "$COUNT_DIR2"/worker-*.csv)
flog "Part 2 TOTAL requests issued: $TOTAL_N2"
AFTER2=$(gw_metrics gateway-faults)
echo "$AFTER2" > "$OUT_DIR/gateway-metrics-part2.txt"
flog "-- Part 2 gateway-faults /metrics --"
echo "$AFTER2" | grep -E '^inference_(retries_total|sheds_total|requests_total|backend_healthy)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
