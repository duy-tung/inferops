# Security — inferops

Scope: operational security of the deployment stack. Application security (authn, tenant isolation, API-key hashing) is infergate's domain; inferops verifies exposure boundaries and handles only operational credentials.

## 1. Secret strategy

- **No secrets in manifests or git.** Kubernetes Secrets are created **out-of-band** by a script that reads from local env/files excluded from git (`.gitignore`d paths; the script itself is committed, its inputs never are).
- Rotation: a documented procedure — create new Secret version, roll consumers (paired with the config-rollout mechanics of IO-T010), verify, delete old version. Verified in the IO-T010 walkthrough.
- SOPS / sealed-secrets are **not** in the baseline: single operator, single local cluster, no shared-repo secret distribution need. Admitted only if a real need emerges, via ADR (consistent with ADR-0001's smallest-set principle).
- CI never receives real secrets; smoke/lifecycle tiers run with dev-grade generated credentials.

## 2. API-key material handling

- Gateway tenant API keys are **infergate's domain** (hashed at rest in PostgreSQL). inferops never generates, stores, or inspects tenant key material.
- inferops handles only the bootstrap/admin credentials needed to operate the stack (e.g., dev PostgreSQL password, Grafana admin, gateway admin credential): never logged, never baked into images or ConfigMaps, always Kubernetes Secrets created out-of-band per §1.
- Evidence artifacts (smoke transcripts, campaign logs) are reviewed for credential leakage before commit; any test key that appears in output is dev-grade and rotated.

## 3. Image provenance

- Deploy **by digest only**. The digest recorded in a manifest must match the released artifact in the inference-lab pins file.
- No `:latest` tags. No locally built component images (except the llama.cpp engine image, IO-T005 — it is not a portfolio component; see `docs/gpu-node-profile.md`). No component source checkouts (see `docs/scope.md`) — this is auditable across repo history and CI.
- Digest bump procedure (IO-T010): new digest → smoke green → pins file advances. Rollback = previous digest, same procedure.
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
