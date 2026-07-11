# Testing — inferops

Three tiers, all evidence-producing. Everything runs GPU-free except IO-T005 and explicitly GPU-variant runs. CI must be able to spin the kind cluster and run the smoke + lifecycle tiers.

## Tier 1 — Smoke (every deploy, every digest bump)

**What:** contract fixtures from the pinned `serving-contracts` bundle driven against the **in-cluster** gateway.

- Coverage: `POST /v1/chat/completions` stream + non-stream, `GET /v1/models`, `/healthz`, `/readyz`, `/metrics` reachability; SSE framing with terminal `data: [DONE]`; error-envelope classes from the golden fixtures.
- Entry point: `scripts/smoke.sh` (IO-T002). Exit code is the verdict; full transcript captured to an output file that becomes the evidence artifact.
- Gate use: M2 acceptance; re-run on every infergate digest bump **before** the inference-lab pins file advances; re-run on every contract-bundle bump.

## Tier 2 — Lifecycle (IO-T004)

Re-runnable, output-capturing **scripts** — not manual checklists.

- **Rolling-update-under-load** (`scripts/rolling-update-test.sh`): compose analog of a 2-replica
  Deployment (`gateway-a`/`gateway-b` behind haproxy, `compose/docker-compose.lifecycle.yml` +
  `compose/haproxy/haproxy.cfg`) — start scripted live load (a steady short-request stream plus
  periodic long-running SSE streams), roll each replica (drain via `docker compose stop`/SIGTERM,
  then replace), assert zero client-visible errors from the client-side record. This is
  hypothesis H1 and fault scenario 12's mechanism. **Result, 2026-07-11:** 0/27 short requests and
  0/3 long streams were client-visible errors across both replicas' rolls
  (`scripts/evidence/rolling-update-20260711T234628Z/`). Honesty note: infergate has released only
  one image digest, so this rolls the *same* digest — the mechanics under test (drain,
  readiness-gated re-admission) are identical to a real digest bump; `scripts/upgrade.sh` (IO-T010)
  will exercise an actual digest change with the same procedure.
- **Warm-up readiness test** (`scripts/warmup-readiness-test.sh`): mock-backend replaced with a
  delayed-start instance (12s injected startup delay, same released digest) against a *test-defined*
  simulated startupProbe budget (period=2s × failure_threshold=10 = 20s — the mock's own shipped
  descriptor assumes near-instant startup and isn't a stand-in for a slow-warming engine's probe
  config; this test's budget explicitly is). **Result, 2026-07-11:** 5/5 checks passed
  (`scripts/evidence/warmup-readiness-20260711T235223Z/`) — `/healthz` failed 5 times before the
  backend came up at t=14s (within the 20s budget); `inference_backend_healthy{backend="mock"}`
  read 0 throughout and flipped to 1 after; a request sent at t=3s (mid-warm-up) got a definitive
  typed `503` (`"No healthy backend is currently available"`, `param=backend_unavailable`) — no
  silent success, no hang; a request after warm-up succeeded normally; mock-backend's
  `RestartCount` stayed 0 (a startup delay, not a crash-restart loop — scenario 11's mechanism;
  hypothesis H2).
- **Drain test** (`scripts/drain-test.sh`): opens one long-lived stream, confirms it is genuinely
  in-flight (`inference_requests_in_flight=1`), sends SIGTERM to that same container mid-stream,
  and asserts: the in-flight stream still completes (200 + terminal `data: [DONE]`); a *new*
  request sent during the drain window gets a typed `503` (`"Gateway is draining; retry against
  another replica"`); the container exits on its own well inside the grace budget. **Result,
  2026-07-11:** 3/3 passed (`scripts/evidence/drain-test-20260711T234926Z/`) — SIGTERM sent at
  1.04s into the stream, drain waited 961.98ms (matching the stream's remaining length), container
  exited 1s later.
  **Grace-period arithmetic (recorded, deploy/infergate.deployment-contract.json /
  `deploy/infergate/base/deployment.yaml`):** `termination_grace_period_seconds` = **50s** >
  `max_stream_duration_seconds` = **30s** (the gateway's own `-upstream-timeout=30s`) — 50s covers
  the 30s worst-case stream plus a 20s margin for the drain sequence's bookkeeping (readiness flip
  + in-flight settle), grounded in the release's own docker-run SIGTERM smoke evidence
  (`drain_timeout=35s` in RELEASES.md). The drain test above exercised a ~2.3s stream (the mock's
  own maximum completion length, 256 tokens × 8ms), well inside that budget; the arithmetic itself
  is a static property of the two contract numbers, not something that varies by test run.

## Tier 3 — Campaign (IO-T006/T007)

Hypothesis-first fault scenarios per Contract 6:

1. **Hypothesis before injection** — expected gateway semantics (quoted from the pinned contract), expected client-visible behavior, metrics that must move, abort condition.
2. **Scripted injection** — simplest injector that produces the fault (`kubectl delete pod` at a controlled phase before any tc/chaos tooling; chaos tooling requires an ADR).
3. **Observation checklist** — dashboards to capture, log/trace queries to run, metrics to snapshot.
4. **Verdict** — expected-vs-observed in `faults/campaign-matrix.md`, every verdict linked to captured output.

Client impact for streaming-critical scenarios (1, 2, 5, 6, 12) is measured by running **inferbench** (released binary/image) during injection — never a local load driver.

**Flakiness policy:** a scenario that does not reproduce reliably is marked *unreliable* with analysis in the matrix — never quietly retried until green. Semantics mismatches are filed as gateway or contract defects and the scenario is re-run after the fix.

## CI shape (implemented in IO-T002; recorded here as the plan)

- Job 1: lint/validate manifests (kustomize build + schema validation against the pinned bundle where applicable).
- Job 2: spin kind → deploy baseline (digests from manifests) → `scripts/smoke.sh`.
- Job 3 (post-IO-T004): lifecycle tier scripts.
- Auditability: CI never clones component repos and never builds component images — the absence is part of Definition-of-Done evidence.

## Evidence handling

Every test run stores its transcript under an evidence path linked from the task/milestone that consumed it. Numbers carry provenance (measured / source-reported / assumed) + date. Invalid runs are invalidated in place with a note — never deleted, never published as valid.
