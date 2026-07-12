#!/usr/bin/env bash
# Scenario 11 — readiness during model warm-up. Delegates to the existing
# IO-T004 script, which already implements exactly this mechanism.
set -uo pipefail
FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFEROPS_ROOT="$(cd "$FAULTS_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-11/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

echo "== Scenario 11 — delegating to scripts/warmup-readiness-test.sh (IO-T004) ==" | tee "$OUT_DIR/transcript.log"
"$INFEROPS_ROOT/scripts/warmup-readiness-test.sh" 2>&1 | tee -a "$OUT_DIR/transcript.log"
STATUS=${PIPESTATUS[0]}

REAL_EVIDENCE=$(grep -oE 'scripts/evidence/warmup-readiness-[0-9TZ]+' "$OUT_DIR/transcript.log" | tail -1)
echo "" >> "$OUT_DIR/transcript.log"
echo "Underlying evidence directory: $INFEROPS_ROOT/$REAL_EVIDENCE" | tee -a "$OUT_DIR/transcript.log"
echo "$REAL_EVIDENCE" > "$OUT_DIR/underlying-evidence-path.txt"

exit "$STATUS"
