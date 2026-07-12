#!/usr/bin/env bash
# Scenario 09 — usage database failure. Uses the main compose-managed
# -auth-mode=db gateway + inferops-postgres-dev (the only combination in
# this repo with the DB-backed usage ledger enabled).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-09/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"
API_KEY=$(cat "$MAIN_API_KEY_FILE")
GW="http://127.0.0.1:8080"

flog "== Scenario 09 — usage database failure — $(date -u --iso-8601=seconds) =="

usage_count() {
  docker exec inferops-postgres-dev psql -U infergate -d infergate -tA -c "SELECT count(*) FROM usage_ledger;" 2>/dev/null
}

BEFORE_COUNT=$(usage_count)
flog "BEFORE: usage_ledger row count = $BEFORE_COUNT"

flog ""
flog "-- steady baseline traffic (10 requests) before the outage --"
: > "$OUT_DIR/requests.csv"
echo "phase,n,unix_ts,http_code,wall_seconds" >> "$OUT_DIR/requests.csv"
send_batch() {
  local phase="$1" n="$2"
  for i in $(seq 1 "$n"); do
    t0=$(date +%s.%N)
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
      --data-binary @"$FIXTURES/chat-completion-request.json")
    t1=$(date +%s.%N)
    wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
    echo "$phase,$i,$(date +%s),$code,$wall" >> "$OUT_DIR/requests.csv"
  done
}
send_batch "before" 10

flog ""
flog "-- docker stop inferops-postgres-dev (the outage) --"
STOP_AT=$(date -u --iso-8601=seconds)
docker stop inferops-postgres-dev >>"$OUT_DIR/transcript.log" 2>&1
flog "stopped at $STOP_AT"

flog ""
flog "-- traffic DURING the outage (15 requests) --"
send_batch "during" 15

flog ""
flog "-- usage_ledger row count during the outage (DB is down; expect this query to fail -- that's expected, it proves the DB is really down, not that the gateway depends on it) --"
DURING_COUNT=$(usage_count || echo "DB_UNREACHABLE (expected)")
flog "DURING: usage_ledger row count query result = $DURING_COUNT"

flog ""
flog "-- docker start inferops-postgres-dev (restore) --"
START_AT=$(date -u --iso-8601=seconds)
docker start inferops-postgres-dev >>"$OUT_DIR/transcript.log" 2>&1
for _ in $(seq 1 20); do
  docker exec inferops-postgres-dev pg_isready -U infergate -d infergate >/dev/null 2>&1 && break
  sleep 1
done
flog "restored at $START_AT"

flog ""
flog "-- traffic AFTER recovery (10 requests) --"
send_batch "after" 10

flog ""
flog "-- waiting up to 30s for the usage backlog to drain --"
for i in $(seq 1 30); do
  AFTER_COUNT=$(usage_count)
  flog "  t+${i}s: usage_ledger row count = $AFTER_COUNT"
  [[ "$AFTER_COUNT" -ge $((BEFORE_COUNT + 20)) ]] && break
  sleep 1
done

flog ""
flog "-- duplicate-settlement idempotency spot check (any request_id settled more than once?) --"
docker exec inferops-postgres-dev psql -U infergate -d infergate -tA -c \
  "SELECT request_id, count(*) FROM usage_ledger GROUP BY request_id HAVING count(*) > 1 LIMIT 5;" \
  > "$OUT_DIR/duplicate-check.txt" 2>&1
DUP_COUNT=$(wc -l < "$OUT_DIR/duplicate-check.txt" | tr -d ' ')
flog "duplicate request_id rows found: $DUP_COUNT (0 expected)"

flog ""
flog "-- client-side latency/error summary by phase --"
python3 -c "
import csv, collections
rows = list(csv.DictReader(open('$OUT_DIR/requests.csv')))
by_phase = collections.defaultdict(list)
for r in rows:
    by_phase[r['phase']].append(r)
for phase in ['before','during','after']:
    rs = by_phase[phase]
    codes = collections.Counter(r['http_code'] for r in rs)
    walls = sorted(float(r['wall_seconds']) for r in rs)
    print(phase, 'n=', len(rs), 'codes=', dict(codes), 'wall min/median/max=',
          round(walls[0],3), round(walls[len(walls)//2],3), round(walls[-1],3))
" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "BEFORE_COUNT=$BEFORE_COUNT AFTER_COUNT=$AFTER_COUNT"
flog "Evidence directory: $OUT_DIR"
