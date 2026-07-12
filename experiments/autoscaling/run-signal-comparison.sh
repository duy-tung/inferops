#!/usr/bin/env bash
# IO-T009 — H-AS-1 signal-comparison experiment.
#
# Stands up ONE gateway replica running the exact admission-sane-v1
# configuration inferbench's IB-T010 E2 experiment used (same flags, same
# mock-backend timing), drives a 5-phase load ramp
# (experiments/autoscaling/workloads/signal-comparison-ramp.json) that
# crosses this replica's real capacity knee, and captures the candidate
# autoscaling signals from REAL Prometheus + REAL docker stats throughout
# (experiments/autoscaling/poll_signals.py, polled once per second in the
# background while inferbench drives load in the foreground). Reuses
# faults/lib.sh's container helpers (same released digests, same pattern as
# the IO-T006/T007 fault campaign) rather than duplicating them.
#
# Container short names (gateway-signals / mock-signals) are chosen to match
# compose/prometheus/prometheus.yml's static scrape targets exactly --
# faults/lib.sh's start_gateway/start_mock use the short name as BOTH the
# container name suffix (inferops-<name>) and the compose-network DNS alias,
# so the name passed here IS the Prometheus target hostname.
#
# See experiments/autoscaling/hypotheses.md H-AS-1 for the hypothesis
# written before this run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
EXP_DIR="$ROOT/experiments/autoscaling"
source "$ROOT/faults/lib.sh"

OUT_DIR="${OUT_DIR:-$EXP_DIR/evidence/signal-comparison-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

flog "== IO-T009 H-AS-1 signal comparison — $(date -u --iso-8601=seconds) =="
flog "Hypothesis: experiments/autoscaling/hypotheses.md H-AS-1"
flog "Workload: experiments/autoscaling/workloads/signal-comparison-ramp.json (seed 20260712101)"

flog ""
flog "-- starting mock-signals (-ttft=80ms -itl=10ms, IB-T010 E2's own mock-backend timing) --"
start_mock mock-signals -ttft=80ms -itl=10ms -error-rate=0

flog "-- starting gateway-signals (admission-sane-v1: budget=6, tenant-queue-cap=3, global-queue-cap=3, deadline=500ms — IB-T010 E2's exact admission-sane-v1 flags) --"
start_gateway gateway-signals 8095 mock-signals \
  -upstream-timeout=30s -stream-write-timeout=30s \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=6 \
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms

wait_ready "http://127.0.0.1:8095/readyz" 30 || { flog "gateway-signals did not become ready"; exit 1; }
flog "gateway-signals ready"

flog ""
flog "-- confirming Prometheus scrape target is up before starting the timed run --"
health="missing"
for _ in $(seq 1 15); do
  health=$(curl -s "http://127.0.0.1:9090/api/v1/targets" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    if t['labels'].get('job')=='infergate-gateway-signals':
        print(t['health']); break
else:
    print('missing')
" 2>/dev/null)
  [[ "$health" == "up" ]] && break
  sleep 1
done
flog "infergate-gateway-signals scrape target health: $health"
[[ "$health" == "up" ]] || { flog "ABORT: scrape target never came up — signals would be all-gaps"; stop_gateway gateway-signals; stop_mock mock-signals; exit 1; }

flog ""
flog "-- starting the 1s-resolution signal poller in the background (210s + margin) --"
python3 "$EXP_DIR/poll_signals.py" \
  --duration 225 --interval 1 \
  --job-regex "infergate-gateway-signals" \
  --containers inferops-gateway-signals,inferops-mock-signals \
  --out "$OUT_DIR/signals.csv" \
  > "$OUT_DIR/poll_signals.log" 2>&1 &
POLL_PID=$!
sleep 2  # let the poller take its first sample before load starts

flog "-- driving the 210s load ramp with inferbench (foreground) --"
RUN_DIR="$OUT_DIR/inferbench-run"
run_inferbench "$RUN_DIR" "$EXP_DIR/workloads/signal-comparison-ramp.json" \
  "http://127.0.0.1:8095" "io-t009-signal-comparison" \
  "H-AS-1: queue_depth/in_flight/token_rate detect the offered-load ramp crossing this replica's admission-sane-v1 capacity knee earlier/more stably than the CPU-utilization proxy (fleetlab FL-T006)." \
  mock -- -model mock-8b -stream >/dev/null
IB_EXIT=$?
flog "inferbench exit code: $IB_EXIT"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- waiting for the signal poller to finish its post-load cool-down samples --"
wait "$POLL_PID" 2>/dev/null
flog "poller finished: $(tail -1 "$OUT_DIR/poll_signals.log" 2>/dev/null)"

flog ""
flog "-- final gateway-signals /metrics snapshot --"
gw_metrics gateway-signals | grep -E '^inference_(sheds_total|queue_depth|requests_in_flight|requests_total)' | tee -a "$OUT_DIR/transcript.log"

# Record the phase plan (offered rates + boundaries) alongside the captured
# signals so analyze.py can join by elapsed time without re-parsing the
# workload JSON.
python3 - "$OUT_DIR/phases.json" <<'PY'
import json, sys
phases = [
    {"phase": 1, "label": "quiet (~24% of measured capacity)", "start_s": 0,   "end_s": 45,  "offered_rps": 8},
    {"phase": 2, "label": "approaching (~60%)",                "start_s": 45,  "end_s": 90,  "offered_rps": 20},
    {"phase": 3, "label": "at ~1x (IB-T010 E2 baseline rate)",  "start_s": 90,  "end_s": 150, "offered_rps": 37.8072},
    {"phase": 4, "label": "5x severe overload (IB-T010 E2 overload rate)", "start_s": 150, "end_s": 165, "offered_rps": 189.0362},
    {"phase": 5, "label": "cool-down (scale-in window)",       "start_s": 165, "end_s": 210, "offered_rps": 8},
]
json.dump(phases, open(sys.argv[1], "w"), indent=2)
PY

flog ""
flog "-- running analysis --"
python3 "$EXP_DIR/analyze_signal_comparison.py" \
  --signals-csv "$OUT_DIR/signals.csv" \
  --phases-json "$OUT_DIR/phases.json" \
  --events-jsonl "$RUN_DIR/events.jsonl" \
  --out-md "$OUT_DIR/summary.md" \
  --out-json "$OUT_DIR/summary.json" \
  | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- tearing down --"
stop_gateway gateway-signals
stop_mock mock-signals

flog ""
flog "Evidence directory: $OUT_DIR"
