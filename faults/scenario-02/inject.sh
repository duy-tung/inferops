#!/usr/bin/env bash
# Scenario 02 — backend killed after first token.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-02/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 02 — backend killed after first token — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults (ttft=100ms, itl=500ms) + gateway-faults --"
flog "   (-upstream-timeout=120s on gateway-faults: itl=500ms x the workload's 200-token output"
flog "   cap = up to 100s of legitimate streaming time — well past the gateway's 30s DEFAULT"
flog "   total ceiling. A first run at the 30s default showed 8/60 long completions timing out"
flog "   for that unrelated reason, a confound this run removes so every observed error is"
flog "   actually attributable to the kill.)"
start_mock mock-faults -ttft=100ms -itl=500ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults -upstream-timeout=120s
wait_ready "http://127.0.0.1:8091/readyz" 30
flog "gateway-faults ready"

BEFORE=$(gw_metrics gateway-faults)
flog ""
flog "-- BEFORE: usage/requests/retries counters --"
echo "$BEFORE" | grep -E '^inference_(usage_tokens_total|requests_total|retries_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- launching background inferbench streaming population (rate=4) --"
RUN_DIR="$OUT_DIR/inferbench-run"
(
  run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-chat-short.json" \
    "http://127.0.0.1:8091" "fs02-run" \
    "Post-first-token backend kill: streams already receiving tokens get a standardized SSE error event and are never retried; partial output is settled as usage." \
    mock -- -model mock-8b -stream -rate 4
) &
IB_PID=$!

flog "-- capturing one directly-observed raw SSE stream (long completion) --"
RAW_STREAM="$OUT_DIR/raw-stream.sse"
(
  curl -s -N -m 20 -o "$RAW_STREAM" -X POST "http://127.0.0.1:8091/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"mock-8b","messages":[{"role":"user","content":"count to a lot"}],"max_completion_tokens":500,"stream":true,"stream_options":{"include_usage":true}}' \
    2>/dev/null
) &
RAW_PID=$!

sleep 1.5
KILL_AT=$(date -u --iso-8601=seconds)
flog ""
flog "-- t+1.5s: docker kill -s SIGKILL inferops-mock-faults (at $KILL_AT); every stream is well past its 100ms TTFT --"
docker kill -s SIGKILL inferops-mock-faults >>"$OUT_DIR/transcript.log" 2>&1

flog "-- waiting for the raw captured stream's curl to return --"
wait "$RAW_PID" 2>/dev/null
flog "-- last 10 lines of the captured raw stream --"
tail -10 "$RAW_STREAM" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- restarting mock-faults so the inferbench population can finish (recovery, as in scenario 01) --"
sleep 2
start_mock mock-faults -ttft=100ms -itl=500ms -error-rate=0
for _ in $(seq 1 10); do
  h=$(gw_metrics gateway-faults | grep '^inference_backend_healthy' | awk '{print $2}')
  [[ "$h" == "1" ]] && break
  sleep 1
done
flog "backend_healthy after restart: $h"

flog ""
flog "-- waiting for the background inferbench population to finish --"
wait "$IB_PID"
flog "inferbench exit code: $?"

AFTER=$(gw_metrics gateway-faults)
echo "$AFTER" > "$OUT_DIR/gateway-metrics-after.txt"
flog ""
flog "-- AFTER: usage/requests/retries counters --"
echo "$AFTER" | grep -E '^inference_(usage_tokens_total|requests_total|retries_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- inferbench run summary --"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- events with a non-null ttft (had begun streaming) whose final status was error --"
python3 -c "
import json
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    if e['status'] == 'error' and e.get('ttft_seconds') is not None:
        print(e['request_id'], 'ttft=', round(e['ttft_seconds'],3), 'output_tokens=', e.get('output_tokens'), 'error_class=', e.get('error_class'))
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- full status/error_class breakdown --"
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
flog "-- duplicate-request-id check (no request should ever appear twice) --"
python3 -c "
import json, collections
c = collections.Counter()
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    c[e['request_id']] += 1
dups = {k:v for k,v in c.items() if v > 1}
print('duplicate_request_ids=', dups if dups else 'none')
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down mock-faults / gateway-faults --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
