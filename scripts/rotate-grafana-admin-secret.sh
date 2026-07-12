#!/usr/bin/env bash
# IO-T010: secret rotation walkthrough (docs/security.md §1 "Rotation: a
# documented procedure — create new Secret version, roll consumers, verify,
# delete old version"). Exercised for real against Grafana's admin
# credential — the lowest-risk rotation target in this stack (unlike the
# DB DSN / API-key pepper, rotating it cannot invalidate already-issued
# tenant API keys or break the smoke/lifecycle test fixtures).
#
# Operational fact this script accounts for (recorded, not glossed over):
# Grafana's GF_SECURITY_ADMIN_PASSWORD__FILE env var only seeds the admin
# password at FIRST BOOT (when the admin user row is first created in
# Grafana's own database) — restarting an already-provisioned Grafana with
# a changed secret FILE does not by itself change the live password.
# Rotating a running instance's password is `grafana cli admin
# reset-admin-password`, Grafana's own supported mechanism — so "roll
# consumers" here means running that command against the live container,
# not just recreating it with a new env var.
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
SECRET_FILE="$COMPOSE_DIR/secrets/grafana_admin_password.txt"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/rotate-grafana-secret-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }

log "== inferops IO-T010 secret rotation walkthrough (Grafana admin) — $(date -u --iso-8601=seconds) =="

OLD_PASSWORD="$(cat "$SECRET_FILE")"

log "-- 1/5: verify the OLD credential currently works --"
CODE_OLD_BEFORE=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$OLD_PASSWORD" http://127.0.0.1:3000/api/org)
log "  GET /api/org with old credential: HTTP $CODE_OLD_BEFORE"

log ""
log "-- 2/5: create new Secret version (generate + write, never logged) --"
NEW_PASSWORD="$(openssl rand -hex 16)"
printf '%s' "$NEW_PASSWORD" > "$SECRET_FILE"
chmod 644 "$SECRET_FILE"
log "  new value written to $SECRET_FILE (gitignored, dev-grade, not printed here)"

log ""
log "-- 3/5: roll the consumer (grafana cli admin reset-admin-password against the live container) --"
docker exec -i inferops-grafana grafana cli admin reset-admin-password --password-from-stdin <<<"$NEW_PASSWORD" >>"$OUT_DIR/transcript.log" 2>&1
log "  reset-admin-password executed"

log ""
log "-- 4/5: verify --"
CODE_NEW_AFTER=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$NEW_PASSWORD" http://127.0.0.1:3000/api/org)
CODE_OLD_AFTER=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$OLD_PASSWORD" http://127.0.0.1:3000/api/org)
log "  GET /api/org with NEW credential: HTTP $CODE_NEW_AFTER (expect 200)"
log "  GET /api/org with OLD credential: HTTP $CODE_OLD_AFTER (expect 401 — old value must no longer work)"

log ""
log "-- 5/5: delete old version --"
log "  the old value existed only in the secret file (now overwritten) and this script's"
log "  local variable (unset below, never committed/logged) — no separate copy remains."
unset OLD_PASSWORD NEW_PASSWORD

PASS=0; FAIL=0
[[ "$CODE_OLD_BEFORE" == "200" ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
[[ "$CODE_NEW_AFTER" == "200" ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
[[ "$CODE_OLD_AFTER" == "401" ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

log ""
log "== Summary: $PASS/3 checks passed =="
log "Evidence directory: $OUT_DIR"

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
