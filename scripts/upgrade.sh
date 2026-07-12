#!/usr/bin/env bash
# IO-T010: upgrade procedure — digest bump -> smoke -> pins-file advance
# (docs/security.md §3). Demonstrated against the llama-cpp engine
# component, where this program (uniquely for inferops) can produce a
# genuinely SECOND real digest: infergate itself has released only one
# image digest (v0.1.0), the same limitation docs/testing.md already
# records honestly for scripts/rolling-update-test.sh ("infergate has
# released only one image digest, so this rolls the *same* digest ... a
# future digest bump would use the identical procedure with a different
# `image:` pin" — this script IS that identical procedure, exercised for
# real here because this repo builds+owns the llama-cpp engine image).
#
# The "vNext" candidate is a label-only rebuild of the exact same pinned
# llama.cpp commit/binary (scripts/build-llamacpp-image.sh EXTRA_LABEL) —
# content-identical except metadata, so this script's own digest-bump
# mechanics can be exercised without a real functional change to smoke
# against. Pairs with scripts/rollback.sh, which reverts using the state
# this script records.
#
# Usage: ./scripts/upgrade.sh
# State: scripts/evidence/upgrade-rollback-state/llama-cpp.previous-digest
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE_PATH="$REPO_ROOT/compose/docker-compose.llamacpp.yml"
STATE_DIR="$REPO_ROOT/scripts/evidence/upgrade-rollback-state"
mkdir -p "$STATE_DIR"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/scripts/evidence/upgrade-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

log "== inferops IO-T010 upgrade procedure — $(date -u --iso-8601=seconds) =="

CURRENT_DIGEST=$(grep -A0 'infergate-llamacpp-engine@sha256' "$COMPOSE_FILE_PATH" | grep -o 'sha256:[0-9a-f]*')
log "current (pre-upgrade) digest: $CURRENT_DIGEST"
echo "$CURRENT_DIGEST" > "$STATE_DIR/llama-cpp.previous-digest"

log ""
log "-- 1/5: building the vNext candidate (label-only rebuild, same pinned llama.cpp commit) --"
CANDIDATE_TAG="infergate-llamacpp-engine:8f114a9-upgrade-candidate"
EXTRA_LABEL="inferops.upgrade-test=$(date -u +%Y%m%dT%H%M%SZ)" IMAGE_TAG="$CANDIDATE_TAG" \
  "$REPO_ROOT/scripts/build-llamacpp-image.sh" >>"$OUT_DIR/transcript.log" 2>&1
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$CANDIDATE_TAG" | grep -o 'sha256:[0-9a-f]*')
log "new (candidate) digest: $NEW_DIGEST"
if [[ "$NEW_DIGEST" == "$CURRENT_DIGEST" ]]; then
  log "FATAL: candidate digest is identical to the current one — nothing to upgrade to"
  exit 2
fi

log ""
log "-- 2/5: deploying the candidate digest (compose/docker-compose.llamacpp.yml) --"
sed -i "s#infergate-llamacpp-engine@sha256:[0-9a-f]*#infergate-llamacpp-engine@${NEW_DIGEST}#" "$COMPOSE_FILE_PATH"
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
log "-- 3/5: confirming the RUNNING container actually uses the new digest (not just the compose file) --"
RUNNING_IMAGE=$(docker inspect --format='{{.Image}}' inferops-llama-cpp)
RUNNING_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$RUNNING_IMAGE" 2>/dev/null | grep -o 'sha256:[0-9a-f]*' || echo "$RUNNING_IMAGE")
log "running container image digest: $RUNNING_DIGEST"
if [[ "$RUNNING_DIGEST" != "$NEW_DIGEST" ]]; then
  log "FAIL: running container is not on the new digest"
  exit 1
fi
log "PASS: running container confirmed on the new digest"

log ""
log "-- 4/5: observe — smoke test against the upgraded engine --"
SMOKE_OUT="$OUT_DIR/smoke"
if OUT_DIR="$SMOKE_OUT" "$REPO_ROOT/scripts/llamacpp-smoke.sh" >>"$OUT_DIR/transcript.log" 2>&1; then
  log "PASS: smoke green on the upgraded digest ($NEW_DIGEST)"
  SMOKE_VERDICT=PASS
else
  log "FAIL: smoke failed on the upgraded digest ($NEW_DIGEST) — see $SMOKE_OUT"
  SMOKE_VERDICT=FAIL
fi
tail -5 "$SMOKE_OUT/transcript.log" | tee -a "$OUT_DIR/transcript.log"

log ""
log "-- 5/5: summary =="
log "previous digest: $CURRENT_DIGEST"
log "new digest:      $NEW_DIGEST"
log "smoke verdict:   $SMOKE_VERDICT"
log "state saved:     $STATE_DIR/llama-cpp.previous-digest (used by scripts/rollback.sh)"
log "Evidence directory: $OUT_DIR"
log ""
log "Pins-file advance (manual, human-reviewed step per docs/security.md §3):"
log "  if this were a real release, docs/implementation-notes.md's llama-cpp pin"
log "  would now change from $CURRENT_DIGEST to $NEW_DIGEST."
log "  This script does not auto-edit docs — pin advancement is a reviewed step."

if [[ "$SMOKE_VERDICT" == "PASS" ]]; then
  exit 0
else
  exit 1
fi
