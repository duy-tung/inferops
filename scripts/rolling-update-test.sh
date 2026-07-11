#!/usr/bin/env bash
# IO-T004 evidence: rolling update under live load, measuring client-visible
# errors from the client's own vantage point (hitting the stable haproxy
# endpoint — compose's stand-in for a Kubernetes Service; see
# compose/haproxy/haproxy.cfg's header comment).
#
# Model: 2 gateway replicas (gateway-a, gateway-b) behind haproxy. One
# replica at a time is drained (SIGTERM, respecting the deployment
# contract's stop_grace_period=50s > max_stream_duration_seconds=30s) and
# replaced, while:
#   - a steady stream of short (non-stream) requests hits the LB endpoint
#     continuously ("keep a load stream running");
#   - periodic long-running SSE streams are started so some are in-flight
#     exactly when a replica starts draining, to prove "accepted streams
#     complete" (docs/architecture.md §3 preStop drain requirement).
#
# Honesty note (recorded, not glossed over): infergate has released exactly
# one image digest (v0.1.0); there is no v2 to roll to. This test therefore
# exercises the *mechanics* under test — drain-then-replace, readiness-gated
# re-admission, zero client-visible errors — by recreating each replica from
# the SAME released digest. That is what "rolling update" mechanically means
# at the ops layer; a future digest bump would use the identical procedure
# (scripts/upgrade.sh, IO-T010) with a different `image:` pin.
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
LB="http://127.0.0.1:18080"
FIXTURES="/home/user/serving-contracts/examples/api"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/rolling-update-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"
API_KEY="$(cat "$COMPOSE_DIR/secrets/smoke_api_key.txt")"

cd "$COMPOSE_DIR"
export COMPOSE_FILE="docker-compose.yml:docker-compose.lifecycle.yml"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

log "== inferops rolling-update-under-load test — $(date -u --iso-8601=seconds) =="

log "-- ensuring gateway-a, gateway-b, haproxy are up --"
docker compose --profile lifecycle up -d gateway-a gateway-b haproxy >>"$OUT_DIR/transcript.log" 2>&1
for _ in $(seq 1 30); do
  a=$(curl -s -o /dev/null -w '%{http_code}' "$LB/readyz" 2>/dev/null)
  [[ "$a" == "200" ]] && break
  sleep 1
done
log "haproxy /readyz through LB: $a"

SHORT_LOG="$OUT_DIR/short-requests.csv"
STREAM_LOG="$OUT_DIR/stream-requests.csv"
echo "unix_ts,http_code" > "$SHORT_LOG"
echo "unix_ts,http_code,done_sentinel_seen" > "$STREAM_LOG"

STOP_FLAG="$OUT_DIR/.stop"
rm -f "$STOP_FLAG"

# Background load generator 1: short non-stream requests every ~200ms.
(
  while [[ ! -f "$STOP_FLAG" ]]; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "$LB/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
      --data-binary @"$FIXTURES/chat-completion-request.json" 2>/dev/null)
    echo "$(date +%s.%N),${code:-000}" >> "$SHORT_LOG"
    sleep 0.2
  done
) &
SHORT_PID=$!

# Background load generator 2: a long-running SSE stream every ~2s
# (max_completion_tokens=300 at the mock's itl=8ms => ~2.4s of streaming),
# so some are in-flight exactly when a replica starts draining.
(
  while [[ ! -f "$STOP_FLAG" ]]; do
    tmp=$(mktemp)
    code=$(curl -s -N -m 15 -o "$tmp" -w '%{http_code}' -X POST "$LB/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
      -d '{"model":"mock-8b","messages":[{"role":"user","content":"count"}],"max_completion_tokens":300,"stream":true,"stream_options":{"include_usage":true}}' \
      2>/dev/null)
    done_seen=0
    grep -q '^data: \[DONE\]$' "$tmp" && done_seen=1
    echo "$(date +%s.%N),${code:-000},${done_seen}" >> "$STREAM_LOG"
    rm -f "$tmp"
    sleep 2
  done
) &
STREAM_PID=$!

log "-- load generators started (short: pid $SHORT_PID, stream: pid $STREAM_PID) --"
sleep 3

roll() {
  local svc="$1"
  log ""
  log "-- rolling update: draining $svc (docker compose stop, SIGTERM, grace 50s) --"
  local t0 t1
  t0=$(date +%s)
  docker compose --profile lifecycle stop -t 50 "$svc" >>"$OUT_DIR/transcript.log" 2>&1
  t1=$(date +%s)
  log "$svc drained+stopped in $((t1-t0))s"

  log "-- starting replacement $svc (same released digest — see header note) --"
  docker compose --profile lifecycle up -d "$svc" >>"$OUT_DIR/transcript.log" 2>&1
  for _ in $(seq 1 40); do
    st=$(docker inspect --format='{{.State.Health.Status}}{{if not .State.Health}}n/a{{end}}' "inferops-$svc" 2>/dev/null || true)
    code=$(docker exec "inferops-$svc" wget -q -O /dev/null -S "http://127.0.0.1:8080/readyz" 2>&1 | awk '/HTTP\//{print $2}' | tail -1)
    [[ "$code" == "200" ]] && break
    sleep 1
  done
  log "$svc ready again (readyz=$code)"
  sleep 2   # let haproxy's health check pick it back up (inter 500ms, rise 2)
}

roll gateway-a
roll gateway-b

log ""
log "-- stopping load generators --"
touch "$STOP_FLAG"
wait "$SHORT_PID" "$STREAM_PID" 2>/dev/null

log ""
log "== Results =="
SHORT_TOTAL=$(($(wc -l < "$SHORT_LOG") - 1))
SHORT_ERRORS=$(awk -F, 'NR>1 && $2 !~ /^2/' "$SHORT_LOG" | wc -l)
STREAM_TOTAL=$(($(wc -l < "$STREAM_LOG") - 1))
STREAM_ERRORS=$(awk -F, 'NR>1 && ($2 !~ /^2/ || $3 != 1)' "$STREAM_LOG" | wc -l)

log "short (non-stream) requests: $SHORT_TOTAL total, $SHORT_ERRORS client-visible errors (non-2xx)"
log "long-running SSE streams:    $STREAM_TOTAL total, $STREAM_ERRORS client-visible errors (non-2xx OR missing terminal [DONE])"
log ""
if [[ "$SHORT_ERRORS" -eq 0 && "$STREAM_ERRORS" -eq 0 ]]; then
  log "VERDICT: zero client-visible errors during the rolling update (hypothesis H1 confirmed)"
else
  log "VERDICT: NONZERO client-visible errors observed — reported honestly, not tuned away. See $SHORT_LOG / $STREAM_LOG for the failing rows:"
  awk -F, 'NR>1 && $2 !~ /^2/' "$SHORT_LOG" | tee -a "$OUT_DIR/transcript.log"
  awk -F, 'NR>1 && ($2 !~ /^2/ || $3 != 1)' "$STREAM_LOG" | tee -a "$OUT_DIR/transcript.log"
fi
log ""
log "Evidence directory: $OUT_DIR"
[[ "$SHORT_ERRORS" -eq 0 && "$STREAM_ERRORS" -eq 0 ]] && exit 0 || exit 1
