#!/usr/bin/env bash
# Scenario 05 — gateway termination during streaming. Re-confirms IO-T004's
# scripts/drain-test.sh (single-instance curl-based proof, already evidence)
# with a 2-replica fleet + inferbench client-impact measurement.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-05/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 05 — gateway termination during streaming — $(date -u --iso-8601=seconds) =="
flog "(see also: scripts/evidence/drain-test-20260711T234926Z/ for the IO-T004 single-instance proof)"

flog ""
flog "-- starting fleet: mock-faults + gateway-faults-a/-b + haproxy-faults --"
start_fleet
flog "fleet ready"

RUN_DIR="$OUT_DIR/inferbench-run"
flog ""
flog "-- launching background inferbench streaming population against the LB (rate=4) --"
(
  run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-chat-short.json" \
    "http://127.0.0.1:18091" "fs05-run" \
    "SIGTERM to one of two gateway replicas mid-stream: its in-flight streams complete, new requests land on the other replica, zero client-visible errors." \
    mock -- -model mock-8b -stream -rate 4
) &
IB_PID=$!

sleep 2
TERM_AT=$(date -u --iso-8601=seconds)
flog ""
flog "-- t+2s: docker kill -s SIGTERM inferops-gateway-faults-a (at $TERM_AT) --"
docker kill -s TERM inferops-gateway-faults-a >>"$OUT_DIR/transcript.log" 2>&1

flog "-- polling gateway-faults-a's own /readyz directly (expect non-200 promptly) --"
for i in 1 2 3; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:8092/readyz" 2>/dev/null || echo "000")
  flog "  t+${i}s after SIGTERM: gateway-faults-a /readyz -> $code"
  sleep 1
done

flog ""
flog "-- waiting for gateway-faults-a's container to exit on its own --"
EXIT_T0=$(date +%s)
docker wait inferops-gateway-faults-a > "$OUT_DIR/gateway-faults-a-exit-code.txt" 2>&1
EXIT_T1=$(date +%s)
flog "gateway-faults-a exited $((EXIT_T1-EXIT_T0))s after the poll loop above started (exit code: $(cat "$OUT_DIR/gateway-faults-a-exit-code.txt"))"

flog ""
flog "-- restarting gateway-faults-a (same flags) so the LB has both replicas again --"
start_gateway gateway-faults-a 8092 mock-faults
wait_ready "http://127.0.0.1:8092/readyz" 30

flog ""
flog "-- waiting for the background inferbench population to finish --"
wait "$IB_PID"
flog "inferbench exit code: $?"

flog ""
flog "-- inferbench summary --"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- error/status breakdown --"
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
flog "-- tearing down the fleet --"
stop_fleet

flog ""
flog "Evidence directory: $OUT_DIR"
