#!/usr/bin/env bash
# IO-T010: rollback procedure — revert to the previous digest -> smoke
# (docs/security.md §3 "Rollback = previous digest, same procedure").
# Reads the state scripts/upgrade.sh recorded
# (scripts/evidence/upgrade-rollback-state/llama-cpp.previous-digest) and
# reverts compose/docker-compose.llamacpp.yml's llama-cpp image pin to it,
# then re-runs the same smoke gate.
#
# Usage: ./scripts/rollback.sh  (after ./scripts/upgrade.sh)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE_PATH="$REPO_ROOT/compose/docker-compose.llamacpp.yml"
STATE_FILE="$REPO_ROOT/scripts/evidence/upgrade-rollback-state/llama-cpp.previous-digest"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/scripts/evidence/rollback-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

log "== inferops IO-T010 rollback procedure — $(date -u --iso-8601=seconds) =="

if [[ ! -f "$STATE_FILE" ]]; then
  log "FATAL: $STATE_FILE missing — run scripts/upgrade.sh first"
  exit 2
fi
PREVIOUS_DIGEST="$(cat "$STATE_FILE")"
CURRENT_DIGEST=$(grep -o 'infergate-llamacpp-engine@sha256:[0-9a-f]*' "$COMPOSE_FILE_PATH" | grep -o 'sha256:[0-9a-f]*')
log "currently deployed digest: $CURRENT_DIGEST"
log "rolling back to:           $PREVIOUS_DIGEST"

if [[ "$CURRENT_DIGEST" == "$PREVIOUS_DIGEST" ]]; then
  log "NOTE: already at the previous digest — nothing to roll back (idempotent no-op)"
fi

log ""
log "-- 1/4: reverting the digest pin --"
sed -i "s#infergate-llamacpp-engine@sha256:[0-9a-f]*#infergate-llamacpp-engine@${PREVIOUS_DIGEST}#" "$COMPOSE_FILE_PATH"
grep 'infergate-llamacpp-engine@sha256' "$COMPOSE_FILE_PATH" | tee -a "$OUT_DIR/transcript.log"

( cd "$REPO_ROOT/compose" && export COMPOSE_FILE="docker-compose.yml:docker-compose.llamacpp.yml" && \
  docker compose --profile llamacpp up -d llama-cpp ) >>"$OUT_DIR/transcript.log" 2>&1

for _ in $(seq 1 30); do
  status="$(docker inspect --format='{{.State.Health.Status}}' inferops-llama-cpp 2>/dev/null || echo starting)"
  [[ "$status" == "healthy" ]] && break
  sleep 1
done
log "inferops-llama-cpp health: $status"

log ""
log "-- 2/4: confirming the RUNNING container is back on the previous digest --"
RUNNING_IMAGE=$(docker inspect --format='{{.Image}}' inferops-llama-cpp)
RUNNING_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$RUNNING_IMAGE" 2>/dev/null | grep -o 'sha256:[0-9a-f]*' || echo "$RUNNING_IMAGE")
log "running container image digest: $RUNNING_DIGEST"
if [[ "$RUNNING_DIGEST" != "$PREVIOUS_DIGEST" ]]; then
  log "FAIL: running container is not back on the previous digest"
  exit 1
fi
log "PASS: running container confirmed back on the previous digest"

log ""
log "-- 3/4: observe — smoke test after rollback --"
SMOKE_OUT="$OUT_DIR/smoke"
if OUT_DIR="$SMOKE_OUT" "$REPO_ROOT/scripts/llamacpp-smoke.sh" >>"$OUT_DIR/transcript.log" 2>&1; then
  log "PASS: smoke green after rollback ($PREVIOUS_DIGEST)"
  SMOKE_VERDICT=PASS
else
  log "FAIL: smoke failed after rollback ($PREVIOUS_DIGEST) — see $SMOKE_OUT"
  SMOKE_VERDICT=FAIL
fi
tail -5 "$SMOKE_OUT/transcript.log" | tee -a "$OUT_DIR/transcript.log"

log ""
log "-- 4/4: summary =="
log "rolled back to digest: $PREVIOUS_DIGEST"
log "smoke verdict:         $SMOKE_VERDICT"
log "Evidence directory: $OUT_DIR"

if [[ "$SMOKE_VERDICT" == "PASS" ]]; then
  exit 0
else
  exit 1
fi
