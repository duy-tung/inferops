#!/usr/bin/env bash
# IO-T006/T007 — shared helpers for the Contract 6 fault-injection campaign.
#
# Every scenario script (faults/scenario-NN/inject.sh) sources this file. It
# standardizes how the campaign stands up throwaway gateway/backend
# instances from the SAME released digests already pinned in
# compose/docker-compose.yml (no new images, no source builds — just
# different CLI flags per scenario, exactly like
# scripts/warmup-readiness-test.sh's delayed mock-backend or
# scripts/config-rollout.sh's gateway-llamacpp already do). Container names
# are fixed (gateway-faults[-a|-b], mock-faults[-a|-b|-fleet]) and reused
# across scenario runs — each scenario recreates them with the flags it
# needs and tears them down when done, so scenarios never collide with the
# baseline compose stack (inferops-gateway, inferops-mock-backend, ...) or
# with each other's evidence.
#
# Why -auth-mode=none for every fault-campaign instance: inferbench
# (internal/client/client.go, checked 2026-07-12) sends no Authorization
# header at all, so it can only drive a gateway instance that doesn't
# require one. The baseline compose gateway (-auth-mode=db, port 8080) is
# reserved for scenario 9 (usage-DB failure), the one scenario that
# specifically needs the DB-backed usage ledger inferbench doesn't touch.
set -uo pipefail

FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFEROPS_ROOT="$(cd "$FAULTS_DIR/.." && pwd)"
COMPOSE_DIR="$INFEROPS_ROOT/compose"
NET="inferops-net"

# Same released digests compose/docker-compose.yml pins (IO-T002).
GATEWAY_IMAGE="infergate@sha256:1971426b393b3e00b30cac0690d38b31667b5e34ebbeb6e111a54c369fb54c7e"
MOCK_IMAGE="infergate-mock-backend@sha256:d7df3d5609daa85adef6a07e4471c8bb90f5e2472f0bf3b32deb2fa9efb547e2"

INFERBENCH_BIN="${INFERBENCH_BIN:-/tmp/claude-0/-home-user-ai-infra/f9d2a869-bab7-54d8-a091-357b56be5c68/scratchpad/inferbench-build/inferbench}"
FIXTURES="/home/user/serving-contracts/examples/api"
MAIN_API_KEY_FILE="$COMPOSE_DIR/secrets/smoke_api_key.txt"

flog() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

# start_mock <name> [extra flags...]
# Starts a mock-backend container named inferops-<name>, reachable inside
# inferops-net at both `<name>` and `mock-backend-<name>` DNS aliases.
start_mock() {
  local name="$1"; shift
  docker rm -f "inferops-$name" >/dev/null 2>&1 || true
  docker run -d --name "inferops-$name" --network "$NET" --network-alias "$name" \
    "$MOCK_IMAGE" -addr=:8081 -seed=42 "$@" >/dev/null
}

stop_mock() { docker rm -f "inferops-$1" >/dev/null 2>&1 || true; }

# start_gateway <name> <host_port> <backend_alias> [extra flags...]
# Starts a no-auth gateway instance named inferops-<name>, published on
# 127.0.0.1:<host_port>, routing to http://<backend_alias>:8081.
start_gateway() {
  local name="$1" port="$2" backend_alias="$3"; shift 3
  docker rm -f "inferops-$name" >/dev/null 2>&1 || true
  docker run -d --name "inferops-$name" --network "$NET" --network-alias "$name" \
    -p "127.0.0.1:${port}:8080" \
    "$GATEWAY_IMAGE" \
    -addr=:8080 -admin-addr=:8090 -auth-mode=none \
    -backend-url="http://${backend_alias}:8081" -backend-name="$backend_alias" \
    -backend-health-path=/healthz -trace-exporter=none \
    "$@" >/dev/null
}

stop_gateway() { docker rm -f "inferops-$1" >/dev/null 2>&1 || true; }

HAPROXY_IMAGE="haproxy@sha256:3e29449a6beed63262e36104adf531b4e41b359f61937303f5ea8607987b3748"

# start_fleet [extra gateway flags...] — mock-faults + gateway-faults-a +
# gateway-faults-b + haproxy-faults (LB on 127.0.0.1:18091), all no-auth,
# same released digests. Used by scenarios 5 and 12 (drain / rolling
# update) so inferbench can drive load through a stable LB endpoint.
start_fleet() {
  docker rm -f inferops-gateway-faults-a inferops-gateway-faults-b inferops-haproxy-faults >/dev/null 2>&1 || true
  start_mock mock-faults -ttft=20ms -itl=8ms -error-rate=0
  start_gateway gateway-faults-a 8092 mock-faults "$@"
  start_gateway gateway-faults-b 8093 mock-faults "$@"
  wait_ready "http://127.0.0.1:8092/readyz" 30
  wait_ready "http://127.0.0.1:8093/readyz" 30
  docker run -d --name inferops-haproxy-faults --network "$NET" -p "127.0.0.1:18091:80" \
    -v "$FAULTS_DIR/haproxy-faults.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    "$HAPROXY_IMAGE" >/dev/null
  wait_ready "http://127.0.0.1:18091/readyz" 30
}

stop_fleet() {
  docker rm -f inferops-haproxy-faults inferops-gateway-faults-a inferops-gateway-faults-b inferops-mock-faults >/dev/null 2>&1 || true
}

wait_ready() {
  local url="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    [[ "$code" == "200" ]] && return 0
    sleep 1
  done
  return 1
}

gw_metrics() { docker exec "inferops-$1" wget -qO- http://127.0.0.1:8080/metrics 2>/dev/null; }

prom_query() {
  curl -s "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}

prom_scalar() {
  prom_query "$1" | python3 -c "import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
print(r[0]['value'][1] if r else 'no-data')" 2>/dev/null || echo "unreachable"
}

# write_manifest <path> <run_id> <workload_name> <workload_version> <workload_seed> <hypothesis> <engine_name>
# Minimal benchmark-run manifest (fields inferbench itself cannot know —
# run -h's -manifest flag). This campaign is operational client-impact
# measurement, not a benchmark report, so most fields are honestly filled
# with the fault-campaign's own fixed local-dev topology.
# engine_name: "mock" or "llamacpp" (only affects the recorded engine/model
# block; target_topology is always gateway-mock/via-gateway per the
# benchmark-run schema's fixed enum).
write_manifest() {
  local path="$1" run_id="$2" wname="$3" wversion="$4" wseed="$5" hypothesis="$6" engine_name="${7:-mock}"
  python3 - "$path" "$run_id" "$wname" "$wversion" "$wseed" "$hypothesis" "$engine_name" <<'PYEOF'
import json, sys, datetime
path, run_id, wname, wversion, wseed, hypothesis, engine_name = sys.argv[1:8]
topology = "gateway-mock" if engine_name == "mock" else "via-gateway"
model = "mock-8b" if engine_name == "mock" else "qwen2.5-1.5b-instruct"
doc = {
  "run_id": run_id,
  "target_topology": topology,
  "workload_ref": {"name": wname, "version": wversion, "seed": int(wseed)},
  "engine": {"name": engine_name, "version": "released-digest", "commit": "n/a", "flags": {}},
  "model": {"checkpoint": model, "revision": "n/a", "tokenizer": "engine-native"},
  "hardware": {"gpu_model": None, "gpu_count": 0, "vram_gb": None, "driver_version": None,
               "cuda_version": None, "instance_type": "local-dev-container (linux/amd64, CPU-only)"},
  "gateway": {"version": "infergate@sha256:1971426b393b (v0.1.0 release digest)",
              "config_version": "flags-v1 (static flag config, -auth-mode=none)"},
  "client": {"location": "same-host (loopback)", "rtt_ms": 0.5},
  "warm_up": {"policy": "none"},
  "repetitions": 1,
  "hypothesis": hypothesis,
  "started_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "contracts_bundle_version": "unpinned local checkout (docs/interfaces.md pin as of 2026-07)",
  "notes": "IO-T006/T007 fault-campaign client-impact capture, not a benchmark report: single repetition, no warm-up handling. Recorded per program evidence rules (measured, dated).",
}
with open(path, "w") as f:
    f.write(json.dumps(doc, indent=2) + "\n")
PYEOF
}

# run_inferbench <run_dir> <workload_file> <target_url> <run_id> <hypothesis> [engine_name] -- [extra inferbench flags...]
# engine_name defaults to "mock"; pass "llamacpp" explicitly before the "--"
# separator when targeting the llama.cpp path. Everything after "--" is
# forwarded to `inferbench run` verbatim.
run_inferbench() {
  local run_dir="$1" workload="$2" target="$3" run_id="$4" hypothesis="$5"; shift 5
  local engine_name="mock"
  if [[ "${1:-}" != "--" ]]; then engine_name="$1"; shift; fi
  shift  # drop the "--" separator
  mkdir -p "$run_dir"
  local wname wversion wseed
  wname=$(python3 -c "import json;print(json.load(open('$workload'))['name'])")
  wversion=$(python3 -c "import json;print(json.load(open('$workload'))['version'])")
  wseed=$(python3 -c "import json;print(json.load(open('$workload'))['seed'])")
  write_manifest "$run_dir/manifest-input.json" "$run_id" "$wname" "$wversion" "$wseed" "$hypothesis" "$engine_name"
  "$INFERBENCH_BIN" run -workload "$workload" -target "$target" -out "$run_dir" \
    -manifest "$run_dir/manifest-input.json" -run-id "$run_id" "$@" \
    > "$run_dir/inferbench.stdout.log" 2> "$run_dir/inferbench.stderr.log"
  echo $?
}
