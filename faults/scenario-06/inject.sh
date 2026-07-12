#!/usr/bin/env bash
# Scenario 06 — queue saturation.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-06/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 06 — queue saturation — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults (itl=300ms, slow enough that in-flight slots stay occupied) + gateway-faults with tight admission caps --"
start_mock mock-faults -ttft=20ms -itl=300ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults \
  -admission-tenant-queue-cap=4 -admission-global-inflight-budget=4 \
  -admission-global-queue-cap=8 -admission-queue-deadline=1s
wait_ready "http://127.0.0.1:8091/readyz" 30

flog ""
flog "-- capturing one shed response directly during a manual concurrent burst (for the Retry-After header) --"
: > "$OUT_DIR/burst-headers.txt"
for i in $(seq 1 20); do
  (curl -s -D - -o /dev/null -X POST "http://127.0.0.1:8091/v1/chat/completions" \
    -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json" \
    >> "$OUT_DIR/burst-headers.txt" 2>&1; echo "---" >> "$OUT_DIR/burst-headers.txt") &
done
wait
flog "-- first shed (non-200) response's headers+body from the manual burst --"
awk '/^HTTP\/1.1 [45]/{p=1} p{print} /^---$/{if(p){exit}}' "$OUT_DIR/burst-headers.txt" | tee -a "$OUT_DIR/transcript.log"

sleep 2
flog ""
flog "-- gateway-faults /metrics after the manual burst --"
gw_metrics gateway-faults | grep -E '^inference_(sheds_total|queue_depth|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- running inferbench fault-bursty.json (2 rps base, 25 rps burst) --"
RUN_DIR="$OUT_DIR/inferbench-run"
run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-bursty.json" \
  "http://127.0.0.1:8091" "fs06-run" \
  "A 25 rps burst against a 4-inflight/8-queued admission budget sheds excess requests typed (503 overloaded, Retry-After) while admitted requests keep baseline TTFT." \
  mock -- -model mock-8b -stream >/dev/null
flog "inferbench exit code: $?"

flog ""
flog "-- inferbench summary --"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- ok-population ttft stats (accepted-request latency protection check) --"
python3 -c "
import json
ttfts = []
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    if e['status'] == 'ok' and e.get('ttft_seconds') is not None:
        ttfts.append(e['ttft_seconds'])
ttfts.sort()
if ttfts:
    p50 = ttfts[len(ttfts)//2]
    p95 = ttfts[int(len(ttfts)*0.95)-1] if len(ttfts) > 1 else ttfts[0]
    print(f'n={len(ttfts)} min={min(ttfts):.3f} p50={p50:.3f} p95={p95:.3f} max={max(ttfts):.3f} (mock baseline ttft=20ms)')
else:
    print('no ok events with ttft recorded')
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- shed/error breakdown --"
python3 -c "
import json, collections
c = collections.Counter()
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    c[(e['status'], e.get('error_class'))] += 1
for k, v in sorted(c.items()):
    print(k, v)
" | tee -a "$OUT_DIR/transcript.log"

FINAL_METRICS=$(gw_metrics gateway-faults)
echo "$FINAL_METRICS" > "$OUT_DIR/gateway-metrics-final.txt"
flog ""
flog "-- final sheds/queue-depth --"
echo "$FINAL_METRICS" | grep -E '^inference_(sheds_total|queue_depth)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
