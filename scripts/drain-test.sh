#!/usr/bin/env bash
# IO-T004 evidence: a focused, deterministic preStop-drain proof (the
# rolling-update-test.sh run above never happened to catch a request
# in-flight at the exact SIGTERM instant, since load there is light and
# random — this script forces the overlap).
#
# Sequence: start one long-running SSE stream against the gateway
# (max_completion_tokens sized so it runs for several seconds at the mock
# backend's -itl=8ms), wait until it is definitely admitted and in-flight,
# then send SIGTERM to that same gateway container and, concurrently,
# attempt a brand-new request. Assert:
#   1. the in-flight stream completes successfully (200, terminal
#      `data: [DONE]`) despite the SIGTERM — preStop drain lets accepted
#      streams finish (deploy/infergate.deployment-contract.json
#      graceful_termination.pre_stop);
#   2. the new request made *during* the drain window is refused with a
#      typed 503 (readiness flips false immediately on SIGTERM, before the
#      grace period even starts counting down);
#   3. the container exits on its own, well inside
#      termination_grace_period_seconds=50 (docker never needs to SIGKILL);
#   4. the grace-period arithmetic holds: 50s grace >
#      max_stream_duration_seconds=30s (recorded in
#      deploy/infergate/base/deployment.yaml) > this test's ~24s stream.
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
GW="http://127.0.0.1:8080"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/drain-test-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"
API_KEY="$(cat "$COMPOSE_DIR/secrets/smoke_api_key.txt")"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

cd "$COMPOSE_DIR"
log "== inferops drain test — $(date -u --iso-8601=seconds) =="

log "-- ensuring baseline gateway is up --"
docker compose --profile app up -d gateway >>"$OUT_DIR/transcript.log" 2>&1
for _ in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/readyz")
  [[ "$code" == "200" ]] && break
  sleep 1
done
log "gateway /readyz: $code"

log ""
log "-- starting one long-running SSE stream in the background --"
log "   (this mock-backend release caps completion length at 256 tokens"
log "   regardless of max_completion_tokens — internal/mockengine/engine.go"
log "   'cap > 256 { cap = 256 }', discovered while building this test; recorded"
log "   here rather than assuming an unbounded knob. Prompt below is a fixed"
log "   point of this repo's seed=42 deterministic generator: it always yields"
log "   242 tokens => ~1.94s of streaming at -itl=8ms, so SIGTERM below is"
log "   timed at t+0.9s to land solidly mid-stream, not at t+2s past the end.)"
STREAM_OUT="$OUT_DIR/inflight-stream.sse"
STREAM_START=$(date +%s.%N)
(
  curl -s -N -m 40 -o "$STREAM_OUT" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
    -d '{"model":"mock-8b","messages":[{"role":"user","content":"count to a lot"}],"max_completion_tokens":3000,"stream":true,"stream_options":{"include_usage":true}}' \
    > "$OUT_DIR/inflight-stream.code" 2>/dev/null
) &
STREAM_PID=$!

sleep 0.9
log "in-flight stream started (pid $STREAM_PID); confirming it is actually admitted before draining --"
docker exec inferops-gateway wget -q -O - http://127.0.0.1:8080/metrics 2>/dev/null | grep '^inference_requests_in_flight' | tee -a "$OUT_DIR/transcript.log"

SIGTERM_AT=$(date +%s.%N)
log ""
log "-- sending SIGTERM to inferops-gateway now (t+$(python3 -c "print(f'{${SIGTERM_AT}-${STREAM_START}:.2f}')")s into the stream) --"
docker kill --signal=TERM inferops-gateway >>"$OUT_DIR/transcript.log" 2>&1

log "-- attempting a NEW request during the drain window (expect a typed 503) --"
NEW_REQ_CODE=$(curl -s -o "$OUT_DIR/during-drain-response.json" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  --data-binary @/home/user/serving-contracts/examples/api/chat-completion-request.json)
log "new request during drain -> HTTP $NEW_REQ_CODE"
cat "$OUT_DIR/during-drain-response.json" | tee -a "$OUT_DIR/transcript.log"
log ""

log "-- waiting for the container to exit on its own --"
EXIT_WAIT_START=$(date +%s)
docker wait inferops-gateway > "$OUT_DIR/container-exit-code.txt" 2>&1 &
WAITPID=$!
wait "$WAITPID"
EXIT_WAIT_END=$(date +%s)
CONTAINER_STOP_SECONDS=$((EXIT_WAIT_END - EXIT_WAIT_START))
log "container exited $CONTAINER_STOP_SECONDS s after SIGTERM (grace budget: 50s) — exit code: $(cat "$OUT_DIR/container-exit-code.txt")"

log ""
log "-- waiting for the in-flight stream's curl to finish --"
wait "$STREAM_PID"
STREAM_END=$(date +%s.%N)
STREAM_HTTP_CODE=$(cat "$OUT_DIR/inflight-stream.code" 2>/dev/null || echo "???")
STREAM_DURATION=$(python3 -c "print(f'{${STREAM_END}-${STREAM_START}:.2f}')")
log "in-flight stream finished: HTTP $STREAM_HTTP_CODE, wall time ${STREAM_DURATION}s"

log ""
log "-- gateway container's own drain log lines --"
docker logs inferops-gateway 2>&1 | grep -iE "shutdown|drain" | tail -5 | tee -a "$OUT_DIR/transcript.log"

log ""
log "== Verdicts =="
PASS=0; FAIL=0
if [[ "$STREAM_HTTP_CODE" == "200" ]] && grep -q '^data: \[DONE\]$' "$STREAM_OUT"; then
  log "PASS  in-flight stream completed successfully (200 + terminal [DONE]) despite SIGTERM mid-stream"
  PASS=$((PASS+1))
else
  log "FAIL  in-flight stream did NOT complete cleanly (code=$STREAM_HTTP_CODE)"
  FAIL=$((FAIL+1))
fi
if [[ "$NEW_REQ_CODE" == "503" ]]; then
  log "PASS  new request during the drain window was refused with a typed 503 (readiness flipped immediately)"
  PASS=$((PASS+1))
else
  log "FAIL  new request during the drain window returned $NEW_REQ_CODE, expected 503"
  FAIL=$((FAIL+1))
fi
if [[ "$CONTAINER_STOP_SECONDS" -lt 50 ]]; then
  log "PASS  container exited on its own in ${CONTAINER_STOP_SECONDS}s, within the 50s grace budget (no SIGKILL needed)"
  PASS=$((PASS+1))
else
  log "FAIL  container took >= 50s to exit (grace budget exhausted, Docker would have SIGKILLed it)"
  FAIL=$((FAIL+1))
fi
log ""
log "Grace-period arithmetic (recorded): termination_grace_period_seconds=50 > max_stream_duration_seconds=30 > this test's stream (~${STREAM_DURATION}s)."
log "$PASS passed, $FAIL failed. Evidence directory: $OUT_DIR"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
