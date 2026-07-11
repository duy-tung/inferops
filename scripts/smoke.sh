#!/usr/bin/env bash
# IO-T002 smoke test: drives the compose-deployed gateway with the pinned
# serving-contracts v0.2.0 golden fixtures (stream + non-stream + error
# classes), then validates request/response shapes against the contract
# bundle's own schemas (kit/contracts-validate.py). Assumes the stack is
# already up and bootstrapped: scripts/gen-dev-secrets.sh,
# scripts/bootstrap-dev-db.sh have been run and compose/secrets/smoke_api_key.txt
# exists.
#
# Exit code: 0 all checks passed, 1 otherwise. Every response is captured to
# $OUT_DIR for evidence.
set -uo pipefail

GATEWAY="${GATEWAY_URL:-http://127.0.0.1:8080}"
CONTRACTS_BUNDLE="${CONTRACTS_BUNDLE:-/home/user/serving-contracts}"
FIXTURES="$CONTRACTS_BUNDLE/examples/api"
COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

if [[ ! -f "$COMPOSE_DIR/secrets/smoke_api_key.txt" ]]; then
  echo "FATAL: $COMPOSE_DIR/secrets/smoke_api_key.txt missing — run scripts/bootstrap-dev-db.sh first" | tee -a "$OUT_DIR/transcript.log"
  exit 2
fi
API_KEY="$(cat "$COMPOSE_DIR/secrets/smoke_api_key.txt")"

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

log "== inferops smoke test — $(date -u --iso-8601=seconds) =="
log "gateway: $GATEWAY"
log "contracts bundle: $CONTRACTS_BUNDLE (v0.2.0, commit 484b449)"
log ""

log "-- selftest: contract bundle fixture sweep --"
python3 "$CONTRACTS_BUNDLE/kit/contracts-validate.py" selftest >>"$OUT_DIR/transcript.log" 2>&1
check_status "kit selftest" "0" "$?"
log ""

log "-- GET /healthz --"
code=$(curl -s -o "$OUT_DIR/healthz.json" -w '%{http_code}' "$GATEWAY/healthz")
check_status "healthz" "200" "$code"

log "-- GET /readyz --"
code=$(curl -s -o "$OUT_DIR/readyz.json" -w '%{http_code}' "$GATEWAY/readyz")
check_status "readyz" "200" "$code"

log "-- GET /metrics --"
code=$(curl -s -o "$OUT_DIR/metrics.txt" -w '%{http_code}' "$GATEWAY/metrics")
check_status "metrics reachable" "200" "$code"

log "-- GET /v1/models --"
code=$(curl -s -o "$OUT_DIR/models-response.json" -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "$GATEWAY/v1/models")
check_status "models" "200" "$code"
validate_schema "api.models-response" "$OUT_DIR/models-response.json" "GET /v1/models"

log "-- POST /v1/chat/completions (non-stream, fixture: chat-completion-request.json) --"
code=$(curl -s -o "$OUT_DIR/chat-completion-response.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  --data-binary @"$FIXTURES/chat-completion-request.json")
check_status "non-stream chat completion" "200" "$code"
validate_schema "api.chat-completion-response" "$OUT_DIR/chat-completion-response.json" "non-stream response"

log "-- POST /v1/chat/completions (stream, fixture: chat-completion-request-stream.json) --"
code=$(curl -s -N -o "$OUT_DIR/chat-completion-stream.sse" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  --data-binary @"$FIXTURES/chat-completion-request-stream.json")
check_status "stream chat completion" "200" "$code"
if grep -q '^data: \[DONE\]$' "$OUT_DIR/chat-completion-stream.sse"; then
  log "PASS  stream terminal sentinel  data: [DONE] present"
  PASS=$((PASS+1))
else
  log "FAIL  stream terminal sentinel  data: [DONE] missing"
  FAIL=$((FAIL+1))
fi
validate_schema "api.stream-event" "$OUT_DIR/chat-completion-stream.sse" "SSE transcript"

log "-- Error class: missing Authorization header --"
code=$(curl -s -o "$OUT_DIR/error-missing-auth.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Content-Type: application/json" --data-binary @"$FIXTURES/chat-completion-request.json")
check_status "missing-auth -> 401" "401" "$code"
validate_schema "api.error-response" "$OUT_DIR/error-missing-auth.json" "missing-auth error envelope"

log "-- Error class: invalid API key --"
code=$(curl -s -o "$OUT_DIR/error-bad-auth.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer wrong-key-not-issued" -H "Content-Type: application/json" \
  --data-binary @"$FIXTURES/chat-completion-request.json")
check_status "bad-auth -> 401" "401" "$code"
validate_schema "api.error-response" "$OUT_DIR/error-bad-auth.json" "bad-auth error envelope"

log "-- Error class: invalid request (missing model, fixture: invalid/request-missing-model.json) --"
code=$(curl -s -o "$OUT_DIR/error-invalid-request.json" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  --data-binary @"$FIXTURES/invalid/request-missing-model.json")
check_status "invalid-request -> 400" "400" "$code"
validate_schema "api.error-response" "$OUT_DIR/error-invalid-request.json" "invalid-request error envelope"

log ""
log "== Summary: $PASS passed, $FAIL failed =="
log "Evidence directory: $OUT_DIR"

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
