# Implementation notes — inferops

Running log of notable events: surprises, ecosystem drift, fallbacks taken, contract defects filed, and assumptions. Deviations from the approved plan are recorded under **Deviations** per the program deviation policy:

> When repository evidence forces a deviation from the approved plan, choose the conservative reversible option, record the evidence, decision, consequences, and follow-up under `Deviations`, and continue. Pause only when the deviation changes public contracts, repository ownership, security posture, or milestone scope.

## Running log

### 2026-07-10 — IO-T001 executed

- Created the full 15-file `docs/` set plus `docs/adr/0001-deployment-tooling.md` on an empty repository (branch `main`, no prior commits).
- ADR-0001 records the program-default tooling decision (Kustomize + raw manifests; no Helm/Argo CD/Terraform in baseline). Pending human review — a mandatory review point before IO-T002 starts.
- The `serving-contracts` bundle tag is not yet pinned (no bundle release visible at bootstrap time); `docs/interfaces.md` carries an explicit "pin not yet set" marker to be filled when IO-T002 starts.

## Assumptions (reversible; recorded per working-style rules)

| # | Date | Assumption | Rationale | Reversal cost |
|---|---|---|---|---|
| A-1 | 2026-07-10 | **kind** (not k3s) is the local base cluster | the testing plan requires CI to spin the cluster for smoke + lifecycle tiers; kind is the CI-reproducible option; nothing currently needs a persistent local node | low — manifests are cluster-agnostic; a dedicated kind-vs-k3s ADR is written with CI evidence during IO-T002 (listed as a "later" ADR in the docs plan) |
| A-2 | 2026-07-10 | Volatile ecosystem facts (vLLM v0.24.x pin, llama.cpp commit, NVIDIA device-plugin details, OTel GenAI semconv "Development" status, GPU spot prices) are stated as of 2026-07 and flagged for re-verification at use time | program rule for volatile facts; none is load-bearing before IO-T002/T005 | none — re-verified at each use site |

## Contract defects filed

*(none yet)*

## Deviations

*(none)*
