#!/usr/bin/env bash
# Scenario 12 — rolling update with active requests. Re-confirms IO-T004's
# scripts/rolling-update-test.sh (already evidence: 0/27 short + 0/3 stream
# errors) with a fresh inferbench-driven run against a no-auth fleet, since
# docs/testing.md requires inferbench specifically for this scenario's
# client-impact number and the original script used curl accounting.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-12/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 12 — rolling update with active requests — $(date -u --iso-8601=seconds) =="
flog "(see also: scripts/evidence/rolling-update-20260711T234628Z/ for the IO-T004 curl-based proof)"

flog ""
flog "-- starting fleet: mock-faults + gateway-faults-a/-b + haproxy-faults --"
start_fleet
flog "fleet ready"

RUN_DIR="$OUT_DIR/inferbench-run"
flog ""
flog "-- launching background inferbench streaming population against the LB (rate=4) for the whole roll --"
(
  run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-chat-short.json" \
    "http://127.0.0.1:18091" "fs12-run" \
    "A full rolling update (drain+replace both replicas in sequence) under continuous streaming load yields zero client-visible errors." \
    mock -- -model mock-8b -stream -rate 4
) &
IB_PID=$!

sleep 2

roll() {
  local svc="$1" port="$2"
  flog ""
  flog "-- rolling: draining $svc (SIGTERM) --"
  local t0 t1
  t0=$(date +%s)
  docker kill -s TERM "inferops-$svc" >>"$OUT_DIR/transcript.log" 2>&1
  docker wait "inferops-$svc" > /dev/null 2>&1
  t1=$(date +%s)
  flog "$svc drained+exited in $((t1-t0))s"

  flog "-- starting replacement $svc (same released digest) --"
  start_gateway "$svc" "$port" mock-faults
  wait_ready "http://127.0.0.1:${port}/readyz" 30
  flog "$svc ready again"
  sleep 1  # let haproxy's health check (inter 500ms, rise 2) pick it back up
}

roll gateway-faults-a 8092
roll gateway-faults-b 8093

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
