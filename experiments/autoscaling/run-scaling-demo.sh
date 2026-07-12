#!/usr/bin/env bash
# IO-T009 — H-AS-2 scaling demonstration (compose-scaling, not HPA pod
# rescheduling — RQ-14, see docs/implementation-notes.md Deviations D-1).
#
# BEFORE: 1 gateway-signals replica (admission-sane-v1, same config as
# run-signal-comparison.sh) takes the full sustained-overload workload
# directly.
# AFTER: a second replica (gateway-signals-2 + mock-signals-2) is brought
# up, both behind haproxy-signals (experiments/autoscaling/haproxy-signals.cfg),
# and the IDENTICAL seeded workload is re-run against the haproxy VIP.
#
# Same workload, same seed, both times — the single declared variable is
# replica_count 1 -> 2, mirroring (at reduced scale) the
# "single_declared_variable" re_measurement plan FL-T009's own recommendation
# JSON specifies for its 1 -> 6 scale-out claim.
#
# See experiments/autoscaling/hypotheses.md H-AS-2 for the hypothesis
# written before this run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
EXP_DIR="$ROOT/experiments/autoscaling"
source "$ROOT/faults/lib.sh"

OUT_DIR="${OUT_DIR:-$EXP_DIR/evidence/scaling-demo-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

WORKLOAD="$EXP_DIR/workloads/scaling-demo-sustained.json"
HAPROXY_IMAGE="haproxy@sha256:3e29449a6beed63262e36104adf531b4e41b359f61937303f5ea8607987b3748"

flog "== IO-T009 H-AS-2 scaling demonstration — $(date -u --iso-8601=seconds) =="
flog "Hypothesis: experiments/autoscaling/hypotheses.md H-AS-2"
flog "Workload: $WORKLOAD (seed 20260712102, 50 rps sustained, 60s)"

cleanup_all() {
  docker rm -f inferops-haproxy-signals >/dev/null 2>&1 || true
  stop_gateway gateway-signals-2
  stop_mock mock-signals-2
  stop_gateway gateway-signals
  stop_mock mock-signals
}
trap cleanup_all EXIT

flog ""
flog "############################################"
flog "## BEFORE — 1 replica (admission-sane-v1)  ##"
flog "############################################"
start_mock mock-signals -ttft=80ms -itl=10ms -error-rate=0
start_gateway gateway-signals 8095 mock-signals \
  -upstream-timeout=30s -stream-write-timeout=30s \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=6 \
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms
wait_ready "http://127.0.0.1:8095/readyz" 30 || { flog "gateway-signals did not become ready"; exit 1; }

# Confirm the Prometheus target is up (same target reused from
# run-signal-comparison.sh's job list, see compose/prometheus/prometheus.yml)
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

python3 "$EXP_DIR/poll_signals.py" \
  --duration 70 --interval 1 \
  --job-regex "infergate-gateway-signals" \
  --containers inferops-gateway-signals,inferops-mock-signals \
  --out "$OUT_DIR/before-signals.csv" \
  > "$OUT_DIR/before-poll.log" 2>&1 &
POLL_PID=$!
sleep 2

BEFORE_DIR="$OUT_DIR/before-inferbench-run"
run_inferbench "$BEFORE_DIR" "$WORKLOAD" "http://127.0.0.1:8095" "io-t009-scaling-before" \
  "H-AS-2 BEFORE: 1 replica at 50rps sustained — goodput capped near the single-replica capacity, shed rate elevated." \
  mock -- -model mock-8b -stream >/dev/null
flog "before inferbench exit: $?"
tail -1 "$BEFORE_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"
wait "$POLL_PID" 2>/dev/null

BEFORE_METRICS=$(gw_metrics gateway-signals)
echo "$BEFORE_METRICS" > "$OUT_DIR/before-gateway-metrics-final.txt"
flog "-- before: final gateway-signals metrics --"
echo "$BEFORE_METRICS" | grep -E '^inference_(sheds_total|queue_depth|requests_in_flight|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "############################################"
flog "## SCALING EVENT — compose-scale 1 -> 2    ##"
flog "############################################"
flog "(RQ-14: this is a compose container-count change standing in for what a"
flog " working HPA/queue_depth-signal controller would have driven the"
flog " Deployment's ReplicaSet to do — no live Kubernetes controller runs"
flog " this decision in this environment. See docs/implementation-notes.md.)"

SCALE_START=$(date -u +%s)
start_mock mock-signals-2 -ttft=80ms -itl=10ms -error-rate=0
start_gateway gateway-signals-2 8097 mock-signals-2 \
  -upstream-timeout=30s -stream-write-timeout=30s \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=6 \
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms
wait_ready "http://127.0.0.1:8097/readyz" 30 || { flog "gateway-signals-2 did not become ready"; exit 1; }

health2="missing"
for _ in $(seq 1 15); do
  health2=$(curl -s "http://127.0.0.1:9090/api/v1/targets" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    if t['labels'].get('job')=='infergate-gateway-signals-2':
        print(t['health']); break
else:
    print('missing')
" 2>/dev/null)
  [[ "$health2" == "up" ]] && break
  sleep 1
done
flog "infergate-gateway-signals-2 scrape target health: $health2"

docker rm -f inferops-haproxy-signals >/dev/null 2>&1 || true
docker run -d --name inferops-haproxy-signals --network inferops-net -p "127.0.0.1:8096:80" \
  -v "$EXP_DIR/haproxy-signals.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "$HAPROXY_IMAGE" >/dev/null
wait_ready "http://127.0.0.1:8096/readyz" 30 || { flog "haproxy-signals did not become ready"; exit 1; }
SCALE_END=$(date -u +%s)
flog "scale-out wall time (2nd replica ready + haproxy fronting both): $((SCALE_END - SCALE_START))s"

flog ""
flog "############################################"
flog "## AFTER — 2 replicas behind haproxy       ##"
flog "############################################"

python3 "$EXP_DIR/poll_signals.py" \
  --duration 70 --interval 1 \
  --job-regex "infergate-gateway-signals|infergate-gateway-signals-2" \
  --containers inferops-gateway-signals,inferops-gateway-signals-2,inferops-mock-signals,inferops-mock-signals-2 \
  --out "$OUT_DIR/after-signals.csv" \
  > "$OUT_DIR/after-poll.log" 2>&1 &
POLL_PID=$!
sleep 2

AFTER_DIR="$OUT_DIR/after-inferbench-run"
run_inferbench "$AFTER_DIR" "$WORKLOAD" "http://127.0.0.1:8096" "io-t009-scaling-after" \
  "H-AS-2 AFTER: 2 replicas at the SAME 50rps sustained, same seed — goodput should track demand more closely and shed rate should drop if the linear-scaling assumption (FL-T009 recommendation, explicitly untested) holds at this small scale." \
  mock -- -model mock-8b -stream >/dev/null
flog "after inferbench exit: $?"
tail -1 "$AFTER_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"
wait "$POLL_PID" 2>/dev/null

AFTER_METRICS_1=$(gw_metrics gateway-signals)
AFTER_METRICS_2=$(gw_metrics gateway-signals-2)
echo "$AFTER_METRICS_1" > "$OUT_DIR/after-gateway-signals-metrics-final.txt"
echo "$AFTER_METRICS_2" > "$OUT_DIR/after-gateway-signals-2-metrics-final.txt"
flog "-- after: final gateway-signals (replica 1) metrics --"
echo "$AFTER_METRICS_1" | grep -E '^inference_(sheds_total|queue_depth|requests_in_flight|requests_total)' | tee -a "$OUT_DIR/transcript.log"
flog "-- after: final gateway-signals-2 (replica 2) metrics --"
echo "$AFTER_METRICS_2" | grep -E '^inference_(sheds_total|queue_depth|requests_in_flight|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- computing before/after summary --"
python3 "$EXP_DIR/analyze_scaling_demo.py" \
  --before-events "$BEFORE_DIR/events.jsonl" \
  --after-events "$AFTER_DIR/events.jsonl" \
  --out-md "$OUT_DIR/summary.md" \
  --out-json "$OUT_DIR/summary.json" \
  | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "Evidence directory: $OUT_DIR"
# cleanup_all runs automatically via the EXIT trap.
