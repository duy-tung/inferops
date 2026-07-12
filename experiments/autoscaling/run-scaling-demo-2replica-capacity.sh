#!/usr/bin/env bash
# IO-T009 — H-AS-2 follow-up: 2-replica CAPACITY check.
#
# run-scaling-demo.sh's "after" measurement at 50 rps offered turned out to
# be demand-capped, not capacity-capped (0% shed after scaling -- see
# experiments/autoscaling/report.md's honesty note): 50 rps was below the
# true 2-replica ceiling, so it could show goodput recovering but could not
# by itself test FL-T009's linear-replica-scaling assumption. This script
# drives workloads/scaling-demo-2replica-capacity.json (80 rps, comfortably
# above 2x the single-replica capacity measured elsewhere in this task)
# against the SAME 2-replica admission-sane-v1 topology to get a real
# saturated 2-replica goodput ceiling.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
EXP_DIR="$ROOT/experiments/autoscaling"
source "$ROOT/faults/lib.sh"

OUT_DIR="${OUT_DIR:-$EXP_DIR/evidence/scaling-demo-2replica-capacity-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"
flog() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

WORKLOAD="$EXP_DIR/workloads/scaling-demo-2replica-capacity.json"
HAPROXY_IMAGE="haproxy@sha256:3e29449a6beed63262e36104adf531b4e41b359f61937303f5ea8607987b3748"

flog "== IO-T009 H-AS-2 follow-up: 2-replica capacity check — $(date -u --iso-8601=seconds) =="
flog "Workload: $WORKLOAD (seed 20260712103, 80 rps sustained, 60s, 2 replicas from the start)"

cleanup_all() {
  docker rm -f inferops-haproxy-signals >/dev/null 2>&1 || true
  stop_gateway gateway-signals-2
  stop_mock mock-signals-2
  stop_gateway gateway-signals
  stop_mock mock-signals
}
trap cleanup_all EXIT

start_mock mock-signals -ttft=80ms -itl=10ms -error-rate=0
start_gateway gateway-signals 8095 mock-signals \
  -upstream-timeout=30s -stream-write-timeout=30s \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=6 \
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms
start_mock mock-signals-2 -ttft=80ms -itl=10ms -error-rate=0
start_gateway gateway-signals-2 8097 mock-signals-2 \
  -upstream-timeout=30s -stream-write-timeout=30s \
  -admission-tenant-queue-cap=3 -admission-global-inflight-budget=6 \
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms
wait_ready "http://127.0.0.1:8095/readyz" 30 || { flog "gateway-signals did not become ready"; exit 1; }
wait_ready "http://127.0.0.1:8097/readyz" 30 || { flog "gateway-signals-2 did not become ready"; exit 1; }

docker rm -f inferops-haproxy-signals >/dev/null 2>&1 || true
docker run -d --name inferops-haproxy-signals --network inferops-net -p "127.0.0.1:8096:80" \
  -v "$EXP_DIR/haproxy-signals.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "$HAPROXY_IMAGE" >/dev/null
wait_ready "http://127.0.0.1:8096/readyz" 30 || { flog "haproxy-signals did not become ready"; exit 1; }
flog "2 replicas + haproxy-signals ready"

RUN_DIR="$OUT_DIR/inferbench-run"
run_inferbench "$RUN_DIR" "$WORKLOAD" "http://127.0.0.1:8096" "io-t009-scaling-2replica-capacity" \
  "H-AS-2 follow-up: 80rps against 2 saturated replicas measures the real 2-replica goodput ceiling, comparable to 2x the single-replica capacity figures measured elsewhere in this task and to FL-T009's linear-scaling assumption." \
  mock -- -model mock-8b -stream >/dev/null
flog "inferbench exit: $?"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

M1=$(gw_metrics gateway-signals); M2=$(gw_metrics gateway-signals-2)
echo "$M1" > "$OUT_DIR/gateway-signals-metrics-final.txt"
echo "$M2" > "$OUT_DIR/gateway-signals-2-metrics-final.txt"
flog "-- replica 1 final metrics --"; echo "$M1" | grep -E '^inference_(sheds_total|requests_total)' | tee -a "$OUT_DIR/transcript.log"
flog "-- replica 2 final metrics --"; echo "$M2" | grep -E '^inference_(sheds_total|requests_total)' | tee -a "$OUT_DIR/transcript.log"

python3 - "$RUN_DIR/events.jsonl" "$OUT_DIR/summary.json" "$OUT_DIR/summary.md" <<'PY'
import json, sys, datetime
events_path, out_json, out_md = sys.argv[1:4]
events = [json.loads(l) for l in open(events_path) if l.strip()]
n = len(events)
ok = sum(1 for e in events if e["status"] == "ok")
shed = sum(1 for e in events if e.get("shed"))
def parse(s):
    return datetime.datetime.strptime(s.rstrip("Z"), "%Y-%m-%dT%H:%M:%S.%f")
send_first = min(parse(e["send_ts"]) for e in events)
end_last = max(parse(e["end_ts"]) for e in events if e.get("end_ts"))
wall = (end_last - send_first).total_seconds()
goodput = ok / wall
offered = n / wall
result = {
    "n": n, "ok": ok, "shed": shed, "shed_frac": round(shed/n, 4),
    "wall_s": round(wall, 3), "offered_rps": round(offered, 3), "goodput_rps": round(goodput, 3),
    "fleetlab_fitted_per_replica_rps": 33.159,
    "linear_2x_prediction_rps": 33.159 * 2,
    "rel_diff_vs_linear_2x_pct": round(100 * (goodput - 33.159*2) / (33.159*2), 2),
    "inferbench_overload_empirical_per_replica_rps": 37.925,
    "linear_2x_prediction_overload_empirical_rps": 37.925 * 2,
    "rel_diff_vs_linear_2x_overload_empirical_pct": round(100 * (goodput - 37.925*2) / (37.925*2), 2),
}
json.dump(result, open(out_json, "w"), indent=2)
lines = ["# H-AS-2 follow-up — 2-replica capacity ceiling (measured, not simulated)\n"]
for k, v in result.items():
    lines.append(f"- **{k}**: {v}")
open(out_md, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

flog ""
flog "Evidence directory: $OUT_DIR"
