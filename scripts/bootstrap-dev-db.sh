#!/usr/bin/env bash
# Bootstraps the dev PostgreSQL schema + a smoke-test tenant/key/model.
#
# Why this script exists (recorded honestly, not glossed over): the infergate
# v0.1.0 release ships exactly two artifacts inferops is authorized to consume
# (RELEASES.md) — the gateway image and the mock-backend image. Applying the
# IG-T007 tenancy/auth schema to a fresh dev Postgres requires the release
# commit's `cmd/migrate` tool, which is not shipped as a separate released
# image (infergate's RELEASES.md "Known deferrals" is silent on this because
# it was never in scope for infergate itself — the tool exists in-repo for
# the release owner's own use). Building it is done exactly the same way this
# task's brief authorizes building the gateway/mock-backend images: `git
# archive` of the released commit (49236a3) plus `go build` of one of its own
# cmd/ packages — no other infergate source is read or vendored into this
# repo, and nothing from cmd/migrate is committed here (only this script,
# which reproduces the build on demand). If a real release ever ships a
# migrate image/binary as a first-class artifact, this script should be
# replaced with a straight `docker run` of that artifact — filed as a
# candidate contract/release-process improvement in
# docs/implementation-notes.md.
set -euo pipefail

INFERGATE_COMMIT="49236a3"
INFERGATE_REPO="/home/user/infergate"
COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "== 1/5: building cmd/migrate from infergate release commit ${INFERGATE_COMMIT} (git archive, no working-tree checkout) =="
git -C "$INFERGATE_REPO" archive "$INFERGATE_COMMIT" | tar -x -C "$WORKDIR"
( cd "$WORKDIR" && CGO_ENABLED=0 go build -o migrate ./cmd/migrate )

echo "== 2/5: waiting for postgres-dev to be healthy =="
cd "$COMPOSE_DIR"
docker compose up -d postgres-dev
for _ in $(seq 1 30); do
  status="$(docker inspect --format='{{.State.Health.Status}}' inferops-postgres-dev 2>/dev/null || echo starting)"
  [[ "$status" == "healthy" ]] && break
  sleep 2
done
docker inspect --format='postgres-dev health: {{.State.Health.Status}}' inferops-postgres-dev

echo "== 3/5: applying IG-T007 tenancy/auth/model-registry schema =="
DSN="postgres://infergate:$(cat secrets/postgres_password.txt)@127.0.0.1:15433/infergate?sslmode=disable"
"$WORKDIR/migrate" -dsn "$DSN"

echo "== 4/5: starting mock-backend + gateway =="
docker compose up -d mock-backend
docker compose --profile app up -d gateway
for _ in $(seq 1 30); do
  code="$(docker exec inferops-gateway wget -q -O /dev/null -S http://127.0.0.1:8080/readyz 2>&1 | awk '/HTTP\//{print $2}' | tail -1 || true)"
  [[ "$code" == "200" ]] && break
  sleep 2
done
echo "gateway /readyz: ${code:-never became ready}"

echo "== 5/5: seeding one smoke-test tenant + API key + model via the admin API (loopback-inside-container only — admin port is never published to the host) =="
TENANT_JSON=$(docker exec inferops-gateway wget -q -O - --post-data='{"name":"smoke-tenant","tier":"default"}' --header='Content-Type: application/json' http://127.0.0.1:8090/admin/v1/tenants)
echo "tenant: $TENANT_JSON"
TENANT_ID=$(printf '%s' "$TENANT_JSON" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

KEY_JSON=$(docker exec inferops-gateway wget -q -O - --post-data='{}' --header='Content-Type: application/json' "http://127.0.0.1:8090/admin/v1/tenants/${TENANT_ID}/keys")
echo "key issued (plaintext shown once, dev-only): $KEY_JSON"
API_KEY=$(printf '%s' "$KEY_JSON" | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p')

MODEL_JSON=$(docker exec inferops-gateway wget -q -O - --post-data='{"id":"mock-8b","owned_by":"fixture-org"}' --header='Content-Type: application/json' http://127.0.0.1:8090/admin/v1/models)
echo "model: $MODEL_JSON"

mkdir -p secrets
printf '%s' "$API_KEY" > secrets/smoke_api_key.txt
chmod 600 secrets/smoke_api_key.txt
echo "smoke API key written to compose/secrets/smoke_api_key.txt (gitignored, dev-only)"
