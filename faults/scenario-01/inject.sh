#!/usr/bin/env bash
# Scenario 01 — backend killed before first token. See hypothesis.md for the
# full contract reference and reduced-form note (single-backend deployment).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-01/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 01 — backend killed before first token — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults (ttft=3s, wide pre-first-token window) + gateway-faults --"
start_mock mock-faults -ttft=3s -itl=8ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults
wait_ready "http://127.0.0.1:8091/readyz" 30
flog "gateway-faults ready"

flog ""
flog "-- BEFORE: inference_backend_healthy{backend=mock-faults} --"
BEFORE_HEALTHY=$(gw_metrics gateway-faults | grep '^inference_backend_healthy' || echo "not yet scraped")
flog "$BEFORE_HEALTHY"

flog ""
flog "-- launching background inferbench client load (streaming, rate=4, seed=42042001) --"
RUN_DIR="$OUT_DIR/inferbench-run"
(
  run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-chat-short.json" \
    "http://127.0.0.1:8091" "fs01-run" \
    "Pre-first-token backend kill: requests in flight when the backend dies either retry-and-fail typed (upstream_error) or succeed after the backend recovers; never partial/duplicated output." \
    mock -- -model mock-8b -stream -rate 4
) &
IB_PID=$!

sleep 1.5
KILL_AT=$(date -u --iso-8601=seconds)
flog ""
flog "-- t+1.5s: docker kill -s SIGKILL inferops-mock-faults (at $KILL_AT) --"
docker kill -s SIGKILL inferops-mock-faults >>"$OUT_DIR/transcript.log" 2>&1

sleep 1
flog "-- t+2.5s: inference_backend_healthy{backend=mock-faults} after the kill --"
gw_metrics gateway-faults | grep '^inference_backend_healthy' | tee -a "$OUT_DIR/transcript.log"

sleep 3.5
flog ""
flog "-- t+6s: restarting mock-faults (same alias, same flags) to observe recovery --"
start_mock mock-faults -ttft=3s -itl=8ms -error-rate=0
RESTART_AT=$(date -u --iso-8601=seconds)
flog "restarted at $RESTART_AT"

for _ in $(seq 1 10); do
  h=$(gw_metrics gateway-faults | grep '^inference_backend_healthy' | awk '{print $2}')
  [[ "$h" == "1" ]] && break
  sleep 1
done
flog "-- inference_backend_healthy{backend=mock-faults} after recovery: $h --"

flog ""
flog "-- waiting for the background inferbench run to finish --"
wait "$IB_PID"
IB_EXIT=$?
flog "inferbench exit code: $IB_EXIT"

flog ""
flog "-- gateway-faults /metrics AFTER --"
AFTER_METRICS=$(gw_metrics gateway-faults)
echo "$AFTER_METRICS" > "$OUT_DIR/gateway-metrics-after.txt"
echo "$AFTER_METRICS" | grep -E '^inference_(retries_total|backend_healthy|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- inferbench run summary (run.log tail) --"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- error_class breakdown across the run (events.jsonl) --"
python3 -c "
import json, collections
c = collections.Counter()
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    c[(e['status'], e.get('error_class'))] += 1
for k, v in sorted(c.items()):
    print(k, v)
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- duplicated/oversized output check (output_tokens must never exceed the workload's output cap of 200) --"
python3 -c "
import json
bad = 0
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    if (e.get('output_tokens') or 0) > 200:
        bad += 1
        print('OVERSIZED', e['request_id'], e['output_tokens'])
print('oversized_count=', bad)
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- stage cardinality check: only pre_first_token should ever appear --"
echo "$AFTER_METRICS" | grep '^inference_retries_total' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "== Part 2: transient (probabilistic) pre-first-token failures =="
flog "The hard-kill run above (Part 1) showed inference_retries_total staying at 0: once the"
flog "health poller (200ms interval, internal/route.DefaultPollInterval) marks the single dead"
flog "backend unhealthy, Router.Select fails on the SECOND (retry) call too, and"
flog "internal/reliability/retry.go's Do() returns the earlier lastErr WITHOUT ever reaching the"
flog "'tries>0' branch that increments inference_retries_total (retry.go:99-104) — there is no"
flog "second backend to usefully retry onto, so the implementation does not count a doomed retry."
flog "This part demonstrates the retry mechanism itself DOES work and IS counted, using a"
flog "transient per-request failure (mock -error-rate=0.5) that never touches /healthz: health"
flog "stays 1 throughout, so every retry's Select() succeeds against the SAME backend, and a"
flog "50% chance of success on the retry attempt cleanly demonstrates both fs-01 clauses in one"
flog "population: some requests retry-and-succeed, some retry-and-exhaust-the-budget-and-fail."
flog ""
flog "-- restarting mock-faults with -error-rate=0.5 (transient per-request failure, /healthz unaffected) --"
start_mock mock-faults -ttft=20ms -itl=8ms -error-rate=0.5
start_gateway gateway-faults 8091 mock-faults
wait_ready "http://127.0.0.1:8091/readyz" 30

RUN_DIR2="$OUT_DIR/inferbench-run-part2"
run_inferbench "$RUN_DIR2" "$FAULTS_DIR/workloads/fault-chat-short.json" \
  "http://127.0.0.1:8091" "fs01-run-part2" \
  "Transient 50% pre-first-token failure rate on a healthy-per-/healthz backend: pre-first-token retries recover roughly half the otherwise-failed requests; the rest exhaust the 2-attempt cap and fail typed upstream_error. inference_retries_total{stage=pre_first_token} increases; no other stage ever appears." \
  mock -- -model mock-8b -stream -rate 5 >/dev/null
flog "inferbench (part 2) exit code: $?"

PART2_METRICS=$(gw_metrics gateway-faults)
echo "$PART2_METRICS" > "$OUT_DIR/gateway-metrics-part2.txt"
flog ""
flog "-- gateway-faults /metrics after part 2 --"
echo "$PART2_METRICS" | grep -E '^inference_(retries_total|backend_healthy|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- part 2 inferbench summary --"
tail -1 "$RUN_DIR2/run.log" | tee -a "$OUT_DIR/transcript.log"
flog ""
flog "-- part 2 error_class breakdown --"
python3 -c "
import json, collections
c = collections.Counter()
for line in open('$RUN_DIR2/events.jsonl'):
    e = json.loads(line)
    c[(e['status'], e.get('error_class'))] += 1
for k, v in sorted(c.items()):
    print(k, v)
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down mock-faults / gateway-faults --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
