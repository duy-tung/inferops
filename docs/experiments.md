# Experiments — inferops

Two experiment families: **autoscaling experiments** (IO-T009, I6 verification arm) and the **fault campaign** (IO-T006/T007, I7). Both are hypothesis-first: the hypothesis is written and committed *before* the run. All numbers produced get measured provenance + date.

## 1. Performance hypotheses (program-level, tested here)

- **H1:** rolling update under load with correct probes/drain yields **0 client-visible errors** (scenario 12 target — a program success criterion, not a guess).
- **H2:** with warm-up-aware readiness, a vLLM pod receives **0 requests before warm-up completes** and undergoes **0 liveness restarts** during warm-up (scenario 11).
- **H3:** scaling on queue depth reacts faster than scaling on CPU utilization for token-heavy workloads — tested against fleetlab's prediction; agreement or divergence is reported either way (divergence is a result, not a failure).
- **H4:** killing the observability stack changes gateway request success rate by **0**.

## 2. Autoscaling experiments (IO-T009)

**Mechanism:** HPA baseline. KEDA only if a required signal cannot be served by HPA + a metrics adapter (ADR before adoption). Backends: mock/llama.cpp (GPU variant only if budget remains).

**Signals under test:**

| Signal | Source metric | Note |
|---|---|---|
| queue depth | `inference_queue_depth` | custom-metric path (Prometheus adapter) |
| in-flight requests | `inference_requests_in_flight` | custom-metric path |
| token-arrival rate | derived from `inference_usage_tokens_total` | rate() over the counter |

**Hypothesis template (committed before each run):**

> Scaling on **<signal>** at **<threshold>** keeps **<SLO metric>** within **<bound>** under seeded workload **<workload id + seed>** — as predicted by fleetlab report **<ID>**.

**Per-experiment protocol (one variable at a time):**

1. Fixed baseline topology + pinned images; record the full config.
2. Seeded inferbench load (workload + seed recorded).
3. Scaling configuration under test applied (the only variable).
4. Record: `kubectl get events`, HPA status over time, metric snapshots, scaling event timestamps.
5. Compare observed behavior against the fleetlab prediction for the same workload; write the predicted-vs-observed row.

**Boundary:** inferops never computes what capacity *should* be. The comparison report states observations and agreement/divergence; capacity analysis belongs to fleetlab, and a Contract 7 recommendation is applied verbatim, never edited.

## 3. Fault campaign (IO-T006/T007)

**The 12 Contract 6 scenarios and expected gateway semantics** (vocabulary pinned by the contract bundle; hypothesis docs quote the pinned schema verbatim):

| # | Scenario | Expected gateway semantics |
|---|---|---|
| 1 | backend killed before first token | pre-first-token retry within retry budget or typed 5xx |
| 2 | backend killed after first token | SSE error event, no retry, partial usage settled |
| 3 | slow backend | pressure-aware routing shifts; timeouts typed |
| 4 | slow client | bounded write buffer + write deadline; stream closed, engine released |
| 5 | gateway termination during streaming | drain semantics; accepted streams complete |
| 6 | queue saturation | sheds with 429 + `Retry-After`; accepted-request latency protected |
| 7 | retry storm | retry budget caps amplification |
| 8 | config reload during traffic | snapshot swap, zero dropped streams |
| 9 | usage database failure | requests unaffected; settlement backlog drains idempotently |
| 10 | one unhealthy backend | routing shifts within bounded interval; circuit opens on error rate |
| 11 | readiness during model warm-up | no traffic before warm; no restart loops |
| 12 | rolling update with active requests | zero client-visible errors |

**Hypothesis template** (`faults/scenario-NN/hypothesis.md`, committed before injection):

```markdown
# Scenario NN — <name>
- Contract reference: fault-scenario schema <bundle tag>, scenario NN
- Injection: <exact mechanism, e.g. kubectl delete pod <selector> after first token observed>
- Expected gateway semantics (verbatim from contract): <...>
- Expected client-visible behavior: <...>
- Metrics that must move: <exact Contract 2 names + direction>
- Abort condition: <when to stop the injection>
- Client-impact measurement: <inferbench workload + seed, for scenarios 1, 2, 5, 6, 12>
```

**Adjudication:** verdict = expected-vs-observed in `faults/campaign-matrix.md`, one row per scenario: injected / observed / verdict, each linked to captured output. Mismatch → gateway defect or spec defect filed upstream, scenario re-run after fix. Flaky → marked unreliable with analysis.

**Fallbacks:** GPU-dependent scenarios (especially 11 with real vLLM warm-up) may run on the llama.cpp/mock CPU path with a recorded deviation. If scope reduction triggers, the campaign reduces to scenarios 1, 2, 5, 6, 11, 12 with a documented deviation (`docs/risks.md`).

**Noisy-neighbor observation run (IO-T007 extra):** tenant A at 10× load; verify tenant B protection at the ops level (dashboards show tier isolation). The fairness logic itself is infergate's — this run observes, it does not tune.

## 4. Review lens

Campaign scenarios 6/7/10 (queue saturation, retry storm, unhealthy backend) are adjudicated with the Google SRE overload/cascading-failures checklist (retry amplification, load shedding, cascade containment) — the same written lens applied to the backend-failure/capacity-shortfall/performance-regression runbooks (see `docs/tasks.md` IO-T008).
