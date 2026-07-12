# Security — inferops

Scope: operational security of the deployment stack. Application security (authn, tenant isolation, API-key hashing) is infergate's domain; inferops verifies exposure boundaries and handles only operational credentials.

## 1. Secret strategy (formalized, IO-T010)

- **No secrets in manifests or git.** Kubernetes Secrets are created **out-of-band** by
  `scripts/create-k8s-secrets.sh`, which reads the same gitignored, locally-generated files
  `scripts/gen-dev-secrets.sh` produces for the compose stack (`compose/secrets/*.txt`) and
  applies two Secret objects — `usage-db-credentials` (`dsn`, `postgres-password`) and
  `api-key-pepper` (`pepper`) — via the standard idempotent
  `kubectl create --dry-run=client -o yaml | kubectl apply -f -` pattern. It never echoes a
  secret *value* to stdout, only object names and key *names*. Verified against a live k3s API
  server (`clusters/local/validate-k3s.sh`'s server): both Secrets created in the
  `inferops-local` namespace with exactly the key names `deploy/infergate/base/deployment.yaml`
  and `deploy/postgres-dev/base/statefulset.yaml` already reference via `secretKeyRef`
  (`scripts/evidence/create-k8s-secrets-20260712/transcript.log`). Compose's D-1 bind-mount
  strategy (`compose/docker-compose.yml`'s gateway service) remains the mechanism that actually
  proves the DSN/pepper *values* work end-to-end (real gateway boot against real dev PostgreSQL);
  this script formalizes the equivalent for the Kubernetes-native object, which this sandbox
  cannot schedule a pod against (RQ-14) — the same evidence-shape split as every other manifest in
  this repo (schema/reconciliation proven at the API server; the final kubelet mount step is the
  one link this sandbox cannot execute for anything, secrets included).
- **Rotation** — a documented procedure, walked through for real (IO-T010):
  1. Create new Secret version: generate a new value, write it over the out-of-band file.
  2. Roll consumers: for a live k8s Deployment this is `kubectl apply` (Secret update) +
     `kubectl rollout restart deployment/<name>` — Secret env vars are read once at container
     start, so a running pod does **not** pick up a Secret change without a restart (recorded
     honestly: not exercised end-to-end here, since no pod schedules in this sandbox — the same
     RQ-14 limitation as above). For a **stateful consumer whose own database holds the
     credential** (this program's real example: Grafana's admin password, set only at
     first-boot from `GF_SECURITY_ADMIN_PASSWORD__FILE` — restarting with a new secret *file*
     does **not** change an already-provisioned instance's live password), "roll consumers" means
     invoking that consumer's own rotation mechanism (`grafana cli admin
     reset-admin-password`), not just a restart. This distinction is exactly why the walkthrough
     below exists — a naive "swap the file and restart" procedure would have silently failed to
     rotate anything.
  3. Verify: new value authenticates; old value is rejected.
  4. Delete old version: Kubernetes Secrets have no built-in versioning — "delete" means the old
     value is overwritten in place and never persisted a second place (no local variable/file
     retains it past the rotation).
  - **Executed walkthrough, 2026-07-12** (`scripts/rotate-grafana-admin-secret.sh`,
    `scripts/evidence/rotate-grafana-secret-20260712T003319Z/`): rotated the Grafana admin
    password end-to-end on the live running container — 3/3 checks passed (old value worked
    before rotation; new value works after; old value returns 401 after). Chosen as the walkthrough
    target because it is the lowest-risk credential in the stack: rotating it cannot invalidate the
    already-issued tenant API key (`compose/secrets/smoke_api_key.txt`) or the DB DSN/pepper that
    `scripts/smoke.sh`/`scripts/bootstrap-dev-db.sh` depend on. Rotating those two for real is
    correctly **not** exercised live here: the pepper rotation note above ("rotation invalidates
    every existing key unless issued under the new pepper") is a real, deliberately-not-triggered
    consequence, not an oversight.
  - **Config-rollout pairing** (as this section originally anticipated): the SAME
    reload-without-restart mechanism `scripts/config-rollout.sh` exercises (ADR-0002 snapshot
    swap via `-config` + admin endpoint) is available for gateway config that is NOT a secret;
    genuine Secret rotation for the gateway's DB DSN/pepper still requires a pod restart (Secrets
    are read once at process start, unlike the `-config` file which the process re-reads on
    demand) — recorded here so the two mechanisms are not conflated.
- SOPS / sealed-secrets are **not** in the baseline: single operator, single local cluster, no shared-repo secret distribution need. Admitted only if a real need emerges, via ADR (consistent with ADR-0001's smallest-set principle).
- CI never receives real secrets; smoke/lifecycle tiers run with dev-grade generated credentials.

## 2. API-key material handling

- Gateway tenant API keys are **infergate's domain** (hashed at rest in PostgreSQL). inferops never generates, stores, or inspects tenant key material.
- inferops handles only the bootstrap/admin credentials needed to operate the stack (e.g., dev PostgreSQL password, Grafana admin, gateway admin credential): never logged, never baked into images or ConfigMaps, always Kubernetes Secrets created out-of-band per §1.
- Evidence artifacts (smoke transcripts, campaign logs) are reviewed for credential leakage before commit; any test key that appears in output is dev-grade and rotated.

## 3. Image provenance

- Deploy **by digest only**. The digest recorded in a manifest must match the released artifact in the inference-lab pins file.
- No `:latest` tags. No locally built component images (except the llama.cpp engine image, IO-T005 — it is not a portfolio component; see `docs/gpu-node-profile.md`). No component source checkouts (see `docs/scope.md`) — this is auditable across repo history and CI.
- Digest bump procedure (IO-T010, `scripts/upgrade.sh`/`scripts/rollback.sh`): new digest → smoke
  green → pins note advances (human-reviewed, not auto-edited). Rollback = previous digest, same
  procedure. **Verified 2026-07-12** against the llama-cpp engine image (the one component in
  this repo with two real, distinct digests available — infergate itself has released only one,
  the same limitation `docs/testing.md` already records for `scripts/rolling-update-test.sh`):
  upgrade to a candidate digest → running-container digest confirmed → smoke 22/22 → rollback to
  the previous digest → running-container digest confirmed → smoke 22/22
  (`scripts/evidence/{upgrade,rollback}-20260712T00*/`).
- **Reproducibility finding (IO-T005):** `docker build`'s default provenance-attestation output
  makes the resulting digest **non-deterministic** across rebuilds of byte-identical inputs (the
  attestation manifest embeds build-time metadata) — discovered when two back-to-back builds of
  the llama-cpp engine image from the same context produced two different digests. Fixed with
  `--provenance=false` (verified: three separate rebuilds then produced the identical digest);
  `scripts/build-llamacpp-image.sh` always passes this flag. Recorded as a general lesson for
  digest-pinning any locally built image, not specific to this one component.

## 4. Network exposure

- The gateway **admin surface (`/admin/v1/...`)** and **all `/metrics` endpoints** stay in-cluster: ClusterIP Services only — no Ingress, no NodePort, no LoadBalancer for them. Operator access is via `kubectl port-forward`.
- Only the **public inference API** is exposed for test traffic, and only as far as the test client needs (NodePort/port-forward on the local cluster; never a public endpoint on the GPU node beyond the session's controlled access).
- **Dev PostgreSQL is never exposed outside the cluster.** ClusterIP only; no port-forward left running beyond an active debugging session.
- Observability UIs (Grafana, Prometheus, Tempo) are in-cluster, port-forward access only.

## 5. GPU-node session hygiene

Rented GPU nodes are treated as untrusted-by-default, short-lived infrastructure: no long-lived credentials on the node; auto-stop script + budget alert mandatory per session; teardown script removes workloads, secrets, and the node profile's runtime credentials; the session log records what existed and that it was destroyed.

## 6. Review gates

Secret handling is a mandatory human-review point (IO-T010). Any change to exposure (new Service type, new Ingress, new externally reachable port) is a review-gate item and, if it changes security posture, a pause-for-user item under the deviation policy.
