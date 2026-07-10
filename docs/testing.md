# Testing — inferops

Three tiers, all evidence-producing. Everything runs GPU-free except IO-T005 and explicitly GPU-variant runs. CI must be able to spin the kind cluster and run the smoke + lifecycle tiers.

## Tier 1 — Smoke (every deploy, every digest bump)

**What:** contract fixtures from the pinned `serving-contracts` bundle driven against the **in-cluster** gateway.

- Coverage: `POST /v1/chat/completions` stream + non-stream, `GET /v1/models`, `/healthz`, `/readyz`, `/metrics` reachability; SSE framing with terminal `data: [DONE]`; error-envelope classes from the golden fixtures.
- Entry point: `scripts/smoke.sh` (IO-T002). Exit code is the verdict; full transcript captured to an output file that becomes the evidence artifact.
- Gate use: M2 acceptance; re-run on every infergate digest bump **before** the inference-lab pins file advances; re-run on every contract-bundle bump.

## Tier 2 — Lifecycle (IO-T004)

Re-runnable, output-capturing **scripts** — not manual checklists.

- **Rolling-update-under-load** (`scripts/rolling-update-test.sh`): start scripted live load (inferbench, seeded), trigger a rolling update of the gateway, assert zero client-visible errors from the client-side record. This is hypothesis H1 and fault scenario 12's mechanism.
- **Warm-up readiness test:** deploy a slow-warming backend (mock/llama.cpp with injected startup delay on the CPU path), assert: readiness stays false through warm-up, zero requests routed before ready, zero liveness restarts during warm-up (scenario 11's mechanism; hypothesis H2).
- **Drain test:** open long-lived streams, delete/roll the pod, assert accepted streams complete (preStop drain) and no stream is cut before `terminationGracePeriodSeconds`. The grace-period arithmetic (max stream duration from gateway config → grace period above it) is recorded alongside the test.

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
