#!/usr/bin/env bash
# Generates dev-grade, out-of-band secret material for the compose stack.
# Per docs/security.md §1 ("no secrets in manifests or git"): this script is
# committed; its OUTPUT (compose/secrets/*) is gitignored (compose/.gitignore)
# and re-generated locally by whoever operates the stack. Never commit the
# generated files.
set -euo pipefail

cd "$(dirname "$0")/../compose"
mkdir -p secrets

if [[ -f secrets/postgres_password.txt && -f secrets/infergate_db_dsn.txt && -f secrets/infergate_key_pepper.txt ]]; then
  echo "dev secrets already present under compose/secrets/ — not regenerating (delete the directory to rotate)"
else
  PGPASS="$(openssl rand -hex 24)"
  PEPPER="$(openssl rand -hex 32)"

  printf '%s' "$PGPASS" > secrets/postgres_password.txt
  printf '%s' "$PEPPER" > secrets/infergate_key_pepper.txt
  printf 'postgres://infergate:%s@postgres-dev:5432/infergate?sslmode=disable' "$PGPASS" > secrets/infergate_db_dsn.txt

  chmod 600 secrets/postgres_password.txt
  # world-readable: bind-mounted (not compose `secrets:`) into the gateway
  # container, which reads them as its non-root `infergate` user (uid 100) —
  # see docker-compose.yml's comment on the gateway service for why.
  chmod 644 secrets/infergate_db_dsn.txt secrets/infergate_key_pepper.txt
  echo "generated compose/secrets/{postgres_password,infergate_db_dsn,infergate_key_pepper}.txt"
fi

if [[ -f secrets/grafana_admin_password.txt ]]; then
  echo "grafana admin password already present — not regenerating"
else
  openssl rand -hex 16 > secrets/grafana_admin_password.txt
  chmod 644 secrets/grafana_admin_password.txt  # read by Grafana's container user via bind mount, same rationale as above
  echo "generated compose/secrets/grafana_admin_password.txt"
fi
