# Runbook: Deploy

**Evidence base:** IO-T002 (`docs/implementation-notes.md` "2026-07-11 — IO-T002 executed"),
`scripts/smoke.sh`, `clusters/local/validate-k3s.sh`.

## Symptoms / Trigger

Standing up the inferops stack from nothing: a fresh environment, a rebuilt dev machine, or the
first deploy of a new digest set into a clean namespace.

## Preconditions

- Docker + `docker compose` available; for the Kubernetes-manifest path, a reachable k3s/kind API
  server (`kubectl` context set).
- The pinned `serving-contracts` bundle checked out read-only at `/home/user/serving-contracts`
  (v0.2.0, commit `484b449` as of this repo's last deploy — re-verify the pin in
  `docs/interfaces.md` at deploy time).
- Released infergate images available locally by digest (this repo's pinned set,
  `compose/docker-compose.yml`):
  - gateway: `infergate@sha256:1971426b393b3e00b30cac0690d38b31667b5e34ebbeb6e111a54c369fb54c7e`
  - mock-backend: `infergate-mock-backend@sha256:d7df3d5609daa85adef6a07e4471c8bb90f5e2472f0bf3b32deb2fa9efb547e2`
  If these digests are not present locally, resolve them exactly per `docs/scope.md`'s
  released-images-only rule — never a component source checkout except the one carved-out
  exception this repo already uses (`git archive <release-commit>` + the release's own Dockerfile,
  documented in `RELEASES.md` "Consuming this release").
- No secrets committed anywhere in git (`compose/secrets/` is gitignored) — confirm
  `docs/security.md` §1 before proceeding.

## Procedure

1. **Generate out-of-band dev secrets** (idempotent — skips if already present):
   ```
   scripts/gen-dev-secrets.sh
   ```
   Produces `compose/secrets/{postgres_password,infergate_db_dsn,infergate_key_pepper,grafana_admin_password}.txt`.

2. **Bootstrap dev PostgreSQL + apply schema + seed a smoke tenant**:
   ```
   scripts/bootstrap-dev-db.sh
   ```
   This starts `postgres-dev`, waits for its healthcheck, builds `cmd/migrate` from the pinned
   release commit (the one documented exception to source-checkout — see the script's header
   comment and `docs/implementation-notes.md`'s IO-T002 "Contract-gap candidate filed" entry),
   applies the tenancy/auth schema, starts `mock-backend` and `gateway` (`--profile app`), and
   seeds one smoke tenant + API key + model via the gateway's own admin API (never over a
   published port). Writes `compose/secrets/smoke_api_key.txt`.

3. **Run the smoke test**:
   ```
   scripts/smoke.sh
   ```
   Drives the gateway with the pinned contract bundle's golden fixtures: non-stream + streaming
   chat completions, `/v1/models`, `/healthz`, `/readyz`, `/metrics`, and three error classes
   (missing-auth, bad-auth, invalid-request), each validated against the bundle's own JSON schemas
   via `kit/contracts-validate.py` — not just HTTP-status spot checks. Exit code 0 = deploy
   verified.

4. **(Manifest-correctness path, run alongside or before the runtime deploy above, whenever a
   real Kubernetes cluster is the target):**
   ```
   clusters/local/validate-k3s.sh
   ```
   Renders the Kustomize base (`kubectl kustomize clusters/local`), applies it to a real k3s API
   server, and re-validates with `kubectl apply --dry-run=server`. On a cluster that can actually
   schedule pods (this sandbox cannot — RQ-14, `docs/implementation-notes.md` Deviations D-1), this
   step **is** the deploy: `kubectl apply -k clusters/local` after `scripts/create-k8s-secrets.sh`
   has created the two required Secrets (`docs/security.md` §1), then re-run step 3's contract
   fixtures against the cluster's exposed gateway endpoint instead of `127.0.0.1:8080`.

## Verification

- `scripts/smoke.sh` exits 0 (this repo's last real run: **17/17 passed**,
  `scripts/evidence/smoke-20260711T232118Z/`).
- `docker compose ps` (or `kubectl get pods`) shows all services healthy/Ready.
- `curl http://127.0.0.1:8080/healthz` → 200; `/readyz` → 200; `/metrics` → 200 and contains the
  Contract 2 metric names (`docs/observability.md` §2).
- On the manifest path: `clusters/local/evidence/k3s-validation-*.txt` shows 0 kustomize build
  errors and every object created in etcd.

## Rollback / Escalation

This is a first-time deploy runbook, not a version rollback (see `rollback.md` for reverting an
already-running deploy to a prior digest). If smoke fails on a fresh deploy:

- Check `scripts/evidence/smoke-*/transcript.log` for the first `FAIL` line — it names the exact
  check and expected/actual HTTP code or schema-validation error.
- Common, already-documented causes: dev PostgreSQL schema not applied (`scripts/bootstrap-dev-db.sh`
  ordering matters — gateway's `-auth-mode=db` startup has **no internal DB retry**, see
  `database-outage.md`), or `compose/secrets/smoke_api_key.txt` missing/stale (re-run
  `scripts/bootstrap-dev-db.sh`).
- If the failure traces to a genuine mismatch between the deployment-contract descriptor and the
  manifest/compose service definition, this is a **contract defect**, not a local workaround
  target — file it against `serving-contracts`/`infergate` per `docs/scope.md`, do not silently
  patch around it.
- `docker compose down` (or `kubectl delete -k clusters/local`) tears the attempt down cleanly for
  a retry; `postgres-dev-data` is a named volume — remove it (`docker volume rm`) only if a clean
  schema re-apply is actually intended.

## Walkthrough

**Live-cited.** IO-T002's original run: `scripts/evidence/smoke-20260711T232118Z/` (17/17 passed)
and `clusters/local/evidence/k3s-validation-20260711.txt` (8 objects rendered, 0 build errors, a
real `kubectl apply -k clusters/local` created every object in etcd — Deployment/StatefulSet
controllers correctly created ReplicaSets/Pods from them, all `Pending` with zero registered Nodes,
proving manifest/schema correctness without any pod ever scheduling, per RQ-14).

**Fresh confirmation performed for this runbook (2026-07-12, read-only, no stack mutation):** the
deploy this evidence describes is still the one running — `docker ps` shows `inferops-gateway`,
`inferops-postgres-dev`, `inferops-mock-backend` all `Up`/`healthy`; 5/5 authenticated
`POST /v1/chat/completions` requests against the live gateway returned HTTP 200, and `/readyz`
returned 200, confirming the deployed stack this runbook documents is genuinely still serving
correctly today, not just at the original evidence's timestamp.
