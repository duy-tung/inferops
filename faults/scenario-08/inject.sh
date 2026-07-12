#!/usr/bin/env bash
# Scenario 08 — config reload during traffic. This scenario's injection
# mechanism was already built at IO-T010 (scripts/config-rollout.sh) because
# it IS this scenario's mechanics exactly (ADR-0002 snapshot swap under
# traffic). Per the campaign brief ("CITE and re-confirm rather than redo
# from scratch"), this wrapper re-runs that exact script and records a
# pointer to its evidence directory here rather than re-implementing it.
set -uo pipefail
FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFEROPS_ROOT="$(cd "$FAULTS_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-08/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

echo "== Scenario 08 — delegating to scripts/config-rollout.sh (IO-T010) ==" | tee "$OUT_DIR/transcript.log"
"$INFEROPS_ROOT/scripts/config-rollout.sh" 2>&1 | tee -a "$OUT_DIR/transcript.log"
STATUS=${PIPESTATUS[0]}

REAL_EVIDENCE=$(grep -oE 'scripts/evidence/config-rollout-[0-9TZ]+' "$OUT_DIR/transcript.log" | tail -1)
echo "" >> "$OUT_DIR/transcript.log"
echo "Underlying evidence directory: $INFEROPS_ROOT/$REAL_EVIDENCE" | tee -a "$OUT_DIR/transcript.log"
echo "$REAL_EVIDENCE" > "$OUT_DIR/underlying-evidence-path.txt"

exit "$STATUS"
