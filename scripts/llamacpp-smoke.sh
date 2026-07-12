#!/usr/bin/env bash
# IO-T005 smoke test: drives a REAL completion end-to-end through
# client -> gateway (llamacpp adapter, -auth-mode=none) -> llama.cpp
# (llama-server, real qwen2.5-1.5b-instruct-q4_k_m.gguf) -> back, on the
# compose stack (compose/docker-compose.llamacpp.yml). Covers non-stream,
# streaming, cancellation, and the llamacpp-adapter's own normalization
# contract (docs/implementation-notes.md IO-T005 entry): the gateway must
# echo the CONFIGURED model alias, not llama-server's raw model-path echo,
# and must never leak llama-server's non-standard extras (`timings`,
# `system_fingerprint`, `usage.prompt_tokens_details`) to the client.
#
# Assumes the stack is already up:
#   export COMPOSE_FILE="docker-compose.yml:docker-compose.llamacpp.yml"
#   docker compose --profile llamacpp up -d llama-cpp gateway-llamacpp
#
# Exit code: 0 all checks passed, 1 otherwise. Every response captured to
# $OUT_DIR for evidence.
set -uo pipefail

GATEWAY="${GATEWAY_URL:-http://127.0.0.1:8082}"
CONTRACTS_BUNDLE="${CONTRACTS_BUNDLE:-/home/user/serving-contracts}"
FIXTURES="$(cd "$(dirname "$0")/../compose/llama-cpp/fixtures" && pwd)"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/llamacpp-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0
log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

check_status() {
  local name="$1" expect="$2" got="$3"
  if [[ "$got" == "$expect" ]]; then
    log "PASS  $name  (HTTP $got)"
    PASS=$((PASS+1))
  else
    log "FAIL  $name  (expected HTTP $expect, got $got)"
    FAIL=$((FAIL+1))
  fi
}

check_true() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then
    log "PASS  $name"
    PASS=$((PASS+1))
  else
    log "FAIL  $name"
    FAIL=$((FAIL+1))
  fi
}

validate_schema() {
  local schema="$1" file="$2" label="$3"
  if python3 "$CONTRACTS_BUNDLE/kit/contracts-validate.py" validate --schema "$schema" "$file" >>"$OUT_DIR/transcript.log" 2>&1; then
    log "PASS  schema:$schema  $label"
    PASS=$((PASS+1))
  else
    log "FAIL  schema:$schema  $label"
    FAIL=$((FAIL+1))
  fi
}

log "== inferops IO-T005 llama.cpp real-inference smoke — $(date -u --iso-8601=seconds) =="
log "gateway: $GATEWAY (auth-mode=none, backend=llamacpp)"
log ""

log "-- GET /healthz --"
code=$(curl -s -o "$OUT_DIR/healthz.json" -w '%{http_code}' "$GATEWAY/healthz")
check_status "healthz" "200" "$code"

log "-- GET /readyz --"
code=$(curl -s -o "$OUT_DIR/readyz.json" -w '%{http_code}' "$GATEWAY/readyz")
check_status "readyz" "200" "$code"

log "-- GET /metrics --"
code=$(curl -s -o "$OUT_DIR/metrics-before.txt" -w '%{http_code}' "$GATEWAY/metrics")
check_status "metrics reachable" "200" "$code"

log "-- GET /v1/models --"
code=$(curl -s -o "$OUT_DIR/models-response.json" -w '%{http_code}' "$GATEWAY/v1/models")
check_status "models" "200" "$code"
validate_schema "api.models-response" "$OUT_DIR/models-response.json" "GET /v1/models"
grep -q '"id": *"qwen2.5-1.5b-instruct"' "$OUT_DIR/models-response.json" && \
  check_true "models list carries the configured alias" "true" || \
  check_true "models list carries the configured alias" "false"

log ""
log "-- POST /v1/chat/completions (non-stream, REAL inference) --"
code=$(curl -s -o "$OUT_DIR/chat-completion-response.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
check_status "non-stream chat completion" "200" "$code"
validate_schema "api.chat-completion-response" "$OUT_DIR/chat-completion-response.json" "non-stream response"

log "-- llamacpp-adapter normalization checks (non-stream) --"
MODEL_ECHOED=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['model'])" "$OUT_DIR/chat-completion-response.json" 2>/dev/null || echo "PARSE_ERROR")
if [[ "$MODEL_ECHOED" == "qwen2.5-1.5b-instruct" ]]; then
  check_true "model echoed as configured alias (not llama-server's raw gguf path)" "true"
else
  log "  got model=$MODEL_ECHOED"
  check_true "model echoed as configured alias (not llama-server's raw gguf path)" "false"
fi
if grep -q '"timings"\|"system_fingerprint"\|"prompt_tokens_details"' "$OUT_DIR/chat-completion-response.json"; then
  check_true "no llama-server non-standard extras leaked to client" "false"
else
  check_true "no llama-server non-standard extras leaked to client" "true"
fi

log ""
log "-- POST /v1/chat/completions (stream, REAL inference) --"
code=$(curl -s -N -o "$OUT_DIR/chat-completion-stream.sse" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request-stream.json")
check_status "stream chat completion" "200" "$code"
if grep -q '^data: \[DONE\]$' "$OUT_DIR/chat-completion-stream.sse"; then
  check_true "stream terminal sentinel data: [DONE] present" "true"
else
  check_true "stream terminal sentinel data: [DONE] present" "false"
fi
validate_schema "api.stream-event" "$OUT_DIR/chat-completion-stream.sse" "SSE transcript"
if grep -q '"timings"\|"system_fingerprint"\|"prompt_tokens_details"' "$OUT_DIR/chat-completion-stream.sse"; then
  check_true "no llama-server non-standard extras leaked in stream chunks" "false"
else
  check_true "no llama-server non-standard extras leaked in stream chunks" "true"
fi
# created must be stable across the whole stream (adapter pins it to the
# first chunk's value — llama-server itself restamps per chunk).
CREATED_VALUES=$(grep -o '"created":[0-9]*' "$OUT_DIR/chat-completion-stream.sse" | sort -u | wc -l)
if [[ "$CREATED_VALUES" -le 1 ]]; then
  check_true "created pinned to one value across the whole stream" "true"
else
  log "  saw $CREATED_VALUES distinct created values"
  check_true "created pinned to one value across the whole stream" "false"
fi

log ""
log "-- Cancellation: client disconnects mid-stream (real, not simulated) --"
CANCEL_BEFORE_LLAMA_LOG_LINES=$(docker logs inferops-llama-cpp 2>&1 | wc -l)
timeout 0.6 curl -s -N -X POST "$GATEWAY/v1/chat/completions" -H "Content-Type: application/json" \
  --data-binary @"$FIXTURES/chat-completion-request-long.json" > "$OUT_DIR/cancel-partial.sse" 2>&1
sleep 1.5  # allow gateway's cancel-detection + llama-server's next decode-batch boundary
docker logs inferops-gateway-llamacpp 2>&1 | tail -20 > "$OUT_DIR/gateway-log-tail-after-cancel.txt"
docker logs inferops-llama-cpp 2>&1 | tail -n "+$((CANCEL_BEFORE_LLAMA_LOG_LINES+1))" > "$OUT_DIR/llamacpp-log-tail-after-cancel.txt"

if grep -q 'error_class=canceled' "$OUT_DIR/gateway-log-tail-after-cancel.txt"; then
  check_true "gateway classifies the disconnect as canceled (not an upstream error)" "true"
else
  check_true "gateway classifies the disconnect as canceled (not an upstream error)" "false"
fi
if grep -q 'cancel_point=mid_stream' "$OUT_DIR/gateway-log-tail-after-cancel.txt"; then
  check_true "gateway records cancel_point=mid_stream" "true"
else
  check_true "gateway records cancel_point=mid_stream" "false"
fi
if grep -q 'cancel task' "$OUT_DIR/llamacpp-log-tail-after-cancel.txt"; then
  check_true "llama-server observed the cancellation and freed the slot" "true"
else
  check_true "llama-server observed the cancellation and freed the slot" "false"
fi

log ""
log "-- Post-cancellation liveness: a fresh request still succeeds (slot was freed, not leaked) --"
code=$(curl -s -o "$OUT_DIR/post-cancel-request.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
check_status "post-cancellation request" "200" "$code"

log ""
log "-- GET /metrics (after) — backend=llamacpp series present, cancellation counted --"
code=$(curl -s -o "$OUT_DIR/metrics-after.txt" -w '%{http_code}' "$GATEWAY/metrics")
check_status "metrics reachable (after)" "200" "$code"
if grep -q 'inference_backend_healthy{backend="llamacpp"} 1' "$OUT_DIR/metrics-after.txt"; then
  check_true "inference_backend_healthy{backend=llamacpp}=1" "true"
else
  check_true "inference_backend_healthy{backend=llamacpp}=1" "false"
fi
if grep -q 'inference_requests_total{model="qwen2.5-1.5b-instruct",backend="llamacpp".*error_class="canceled"} [1-9]' "$OUT_DIR/metrics-after.txt"; then
  check_true "inference_requests_total counted the canceled request honestly" "true"
else
  check_true "inference_requests_total counted the canceled request honestly" "false"
fi

log ""
log "== Summary: $PASS passed, $FAIL failed =="
log "Evidence directory: $OUT_DIR"

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
