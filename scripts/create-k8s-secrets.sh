#!/usr/bin/env bash
# IO-T010: formalizes the secret strategy (docs/security.md §1 — "no
# secrets in manifests or git; Kubernetes Secrets are created out-of-band").
# Reads the same gitignored, locally-generated material
# scripts/gen-dev-secrets.sh already produces for the compose stack
# (compose/secrets/*.txt) and creates the two Kubernetes Secret objects
# deploy/infergate/base/deployment.yaml and deploy/postgres-dev/base/
# statefulset.yaml already reference via secretKeyRef:
#   usage-db-credentials  { dsn, postgres-password }
#   api-key-pepper        { pepper }
#
# Idempotent (kubectl apply of a --dry-run=client-generated manifest, the
# standard create-or-update pattern) and never echoes secret VALUES to
# stdout — only kubectl's own summary lines (object name + verb) and key
# NAMES (never values) are printed.
#
# Validated in this environment against the real k3s API server used by
# clusters/local/validate-k3s.sh (server-only, --disable-agent — no pod
# ever mounts these, same evidence shape as every other manifest in this
# repo): this script proves the Secret objects are created correctly and
# carry the expected keys; it cannot prove a live pod successfully mounts
# them (no pod schedules in this sandbox — RQ-14, docs/implementation-notes.md
# "Deviations"). The compose stack's gateway service already proves the
# DSN/pepper VALUES work end-to-end (docker-compose.yml's bind-mount
# equivalent, D-1) — this script proves the K8S-NATIVE secret-object
# mechanics specifically.
set -euo pipefail

export PATH=/home/user/tools/k8s-env/k3s-runtime-bin:/home/user/tools/k8s-env/bin:"$PATH"
KUBECONFIG_PATH="${K3S_KUBECONFIG:-/home/user/tools/k8s-env/kubeconfig-inferops}"
NAMESPACE="${NAMESPACE:-inferops-local}"
COMPOSE_SECRETS="$(cd "$(dirname "$0")/../compose/secrets" && pwd)"

if [[ ! -f "$COMPOSE_SECRETS/postgres_password.txt" ]]; then
  echo "FATAL: $COMPOSE_SECRETS/postgres_password.txt missing — run scripts/gen-dev-secrets.sh first" >&2
  exit 2
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "== ensuring namespace $NAMESPACE exists =="
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

echo
echo "== creating/updating Secret: usage-db-credentials (keys: dsn, postgres-password) =="
PGPASS="$(cat "$COMPOSE_SECRETS/postgres_password.txt")"
DSN="$(cat "$COMPOSE_SECRETS/infergate_db_dsn.txt")"
kubectl create secret generic usage-db-credentials \
  --namespace "$NAMESPACE" \
  --from-literal=dsn="$DSN" \
  --from-literal=postgres-password="$PGPASS" \
  --dry-run=client -o yaml | kubectl apply -f -
unset PGPASS DSN

echo
echo "== creating/updating Secret: api-key-pepper (key: pepper) =="
PEPPER="$(cat "$COMPOSE_SECRETS/infergate_key_pepper.txt")"
kubectl create secret generic api-key-pepper \
  --namespace "$NAMESPACE" \
  --from-literal=pepper="$PEPPER" \
  --dry-run=client -o yaml | kubectl apply -f -
unset PEPPER

echo
echo "== verification: Secret objects exist with the expected key NAMES (never printing values) =="
kubectl get secrets -n "$NAMESPACE" usage-db-credentials api-key-pepper
echo
echo "-- usage-db-credentials keys --"
kubectl get secret usage-db-credentials -n "$NAMESPACE" -o jsonpath='{.data}' | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))"
echo "-- api-key-pepper keys --"
kubectl get secret api-key-pepper -n "$NAMESPACE" -o jsonpath='{.data}' | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))"

echo
echo "== done: $NAMESPACE/usage-db-credentials, $NAMESPACE/api-key-pepper =="
