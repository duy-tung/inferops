# Risks and kill criteria — inferops

## Risk register

| Risk | Likelihood/Impact | Trigger | Mitigation |
|---|---|---|---|
| **R7 — Kubernetes time sink ("YAML exercise")** — the repo's headline risk | L:M, I:M | ops work blocks a wave exit without producing new evidence | smallest-tooling ADR (ADR-0001); ops starts only after gateway behavior is proven (IG-T016 before IO-T002, IG-T014 before IO-T005); runbook/probe scope fixed by the deployment contract; **every task's stop condition is an evidence artifact, not a manifest count**; autoscaling depth is reducible (see below) |
| R2 — GPU budget/availability | — | budget alert fires; no GPU access | G6 gate; IO-T005 is the repo's only GPU task; CPU fallback = llama.cpp-backed I5 variant + fallback subset for GPU-relevant scenarios, all with recorded deviations |
| R3 — ecosystem drift (device plugin, engine metric names, dashboards) | — | scrape/probe configs break on a new pin | pin everything; capability metric-name mapping, never hardcoding; dated "as of 2026-07 — re-verify" provenance flags in every doc that states volatile facts |
| R12 — overclaiming | — | any claim without a log/output | program evidence rules; campaign matrix links every verdict to captured output; invalid runs are invalidated, never published |

## Pre-decided scope reductions

Cut **in this order** if a wave exit is threatened — never silently; each cut is recorded as a deviation in `docs/implementation-notes.md`:

1. **KEDA/autoscaling breadth** → keep ONE HPA experiment + the fleetlab simulation comparison.
2. **Chaos breadth** → the 12 scenarios reduce to the 6 streaming-critical ones: **1, 2, 5, 6, 11, 12** — with a documented deviation.

## Never cut

- Fault-injection evidence entirely (some campaign must run).
- Contract validation (smoke against fixtures).
- The I6 feedback loop (it may shrink to mock/llama.cpp scale but must close).
- Cancellation-correctness observation in scenarios.

## Generic drop rule

Drop or postpone anything that: blocks the critical path without producing new evidence, duplicates an existing capability, lacks a measurable artifact, exceeds GPU budget, or creates source coupling.

## Standing guards

- **Sequencing guard (anti-R7):** the CPU baseline (IO-T002–T004) starts only after infergate has released an image; GPU work only behind gate G6 with a reviewed session plan.
- **Boundary guard (anti-coupling):** any need to clone component source or reimplement load generation is a stop-the-line contract gap, filed upstream — see `docs/scope.md` and `docs/non-goals.md`.
- **Honesty guard (anti-R12):** flaky fault scenarios are marked unreliable with analysis, never quietly retried to green; a wrong fleetlab prediction is a published result with error analysis, never hidden.
