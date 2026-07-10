# Milestones — inferops

Dependency-ordered; no calendar durations. Acceptance is evidence-based: a milestone without its listed artifacts is not done.

| # | Milestone | Depends on | Acceptance criteria |
|---|---|---|---|
| M1 | Docs + tooling ADR | prompt approval | all 15 `docs/` files + the `adr/` directory exist with content; ADR-0001 (tooling) reviewed |
| M2 | CPU cluster baseline | M1; infergate release IG-T016; contracts bundle with deployment/fault schemas | released infergate + mock + dev PostgreSQL deployed **by digest**; contract-fixture smoke test green against the in-cluster gateway; zero source checkouts (auditable) |
| M3 | Observability stack | M2 | OTel Collector, Prometheus, Grafana, Tempo running; golden dashboards render from a test stream using exact Contract 2 metric names; exemplars link a histogram panel to a Tempo trace |
| M4 | Lifecycle semantics | M2 | scripted rolling-update-under-load test: zero client-visible errors; warm-up-aware readiness demonstrated (llama.cpp/mock warm-up simulation on CPU); preStop drain verified; PDB in place; grace period > max stream duration recorded **with arithmetic** |
| M5 | GPU node + vLLM | M4; infergate GPU evidence (IG-T014); GPU gate G6 | in-cluster vLLM serves via gateway; readiness honest during real multi-minute warm-up; driver/CUDA recorded; session auto-stopped; Scenario D smoke green |
| M6 | Campaign part 1 | M3, M4 | scenarios 1–6 injected on mock/llama.cpp path: hypothesis-first, scripted, checklist observed, verdicts recorded |
| M7 | Campaign complete | M6; M5 for GPU-relevant scenarios (CPU fallback allowed with recorded deviation) | 12/12 scenarios executed (or the documented reduced set per `docs/risks.md`); client impact measured via inferbench for scenarios 1, 2, 5, 6, 12 |
| M8 | Runbooks verified | M4 (+M5/M7 for their subjects) | 10 runbooks each verified by tabletop or live walkthrough with notes |
| M9 | Autoscaling experiments | M3; fleetlab signal-comparison outputs | HPA experiments on ≥1 signal run with seeded load; observed-vs-predicted comparison report done |
| M10 | Procedures hardened | M4 | config rollout (scenario 8 in-cluster), secret strategy, upgrade/rollback procedures scripted and verified |

## Integration mapping

- **I5** (operational stack, owned by inferops) requires **M2–M5**.
- **I7** (failure campaign, executed by inferops) requires **M6–M7** (+ **M8** for runbook references).
- **I6** (capacity feedback, verification arm) requires **M9**.

Details and acceptance evidence per integration milestone: `docs/integration.md`.

## Milestone gate procedure

At each gate: run the milestone's verification commands, capture output, link it from the evidence location; then have a fresh-context verifier check the work against these acceptance criteria (self-review alone is not acceptance evidence). Mandatory human-review points: the tooling ADR (M1), the expected-semantics table before M6 starts, every GPU session plan (M5), secret handling (M10), and each wave-exit evidence bundle.
