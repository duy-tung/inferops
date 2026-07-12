# Runbook: Performance Regression

**Evidence base:** IO-T009 (`experiments/autoscaling/results.md`, `experiments/autoscaling/
run-signal-comparison.sh`, `analyze_signal_comparison.py`) — the reference capacity/latency corpus
and signal-detection comparison this runbook's diagnosis leans on; fault scenario 6 (admission
protection); `docs/observability.md` golden dashboard.

**SRE overload/cascading-failures lens applied** per `docs/tasks.md` IO-T008 /
`docs/experiments.md` §4.

## Symptoms / Trigger

- TTFT/ITL/E2E histograms on the golden dashboard creep upward at load levels that were
  previously clean.
- Goodput (successful rps) plateaus below what the known capacity reference predicts.
- Shed fraction climbs at offered-load levels that historically produced little or no shedding.

## Preconditions

- The golden dashboard (`dashboards/golden-dashboard.json`) is live and scraping — if it is not,
  resolve that first via `observability-outage.md` before trying to diagnose a regression through
  a broken observability path.
- A **known-good reference point** to diff against. This repo's own measured reference corpus
  (`experiments/autoscaling/results.md` §4.1, admission-sane-v1 config): ~33.58 rps goodput at
  37.8072 rps offered (measured, +1.3% of fleetlab's independently fitted 33.159 rps/replica);
  ~37.40 rps goodput at 189.0362 rps offered (severe overload, admission-protected); baseline
  authenticated-request latency ~120ms (fault scenario 9's steady-state measurement). A real
  deployment should establish and keep updating its own such reference points as configs/digests
  change — this runbook does not invent new capacity numbers, it diffs against the last trusted
  measurement (never against a guess).

## Diagnosis

1. **Rule out an observability-path artifact first.** A blank or lagging dashboard can look like
   "no data" rather than "no regression" — confirm Prometheus scrape targets are `up` before
   reading any panel as evidence of anything.
2. **Distinguish load-induced latency (expected, protected) from a genuine regression.** The
   admission layer is specifically designed to protect *admitted*-request latency even under heavy
   shedding: fault scenario 6 measured admitted-population TTFT p95=24ms against a 20ms baseline
   even while 392/399 requests were being cleanly shed — that is the system working as intended,
   not a regression. A genuine regression looks different: latency degrading **even for a small,
   clearly-admitted population**, not latency correlating with a rising shed rate.
3. **Check for a correlated change before assuming a capacity regression:**
   - A recent digest bump → treat as an `upgrade.md`/`rollback.md` case first (compare
     before/after digest smoke timing, not just pass/fail).
   - A recent config rollout (admission caps, timeouts) → treat as a `config-rollback.md` case
     first (fault scenarios 6/7 show admission tuning directly changes shed/latency tradeoffs by
     design — a "regression" might just be a config that was tightened on purpose, or tightened by
     mistake).
   - Neither correlates → proceed as a genuine capacity/latency regression and consider
     `capacity-shortfall.md` for the scale-out response.
4. **Use the right signal to confirm overload, not just "is latency worse."** IO-T009's measured
   comparison (`experiments/autoscaling/results.md` §2.2) found:
   - `inference_requests_in_flight` is the most reliable, earliest-firing overload signal for a
     shallow-queue admission profile (fired 6.1s after the true capacity knee, zero false/early
     triggers).
   - `inference_queue_depth` **under-reads** overload for this same profile — it flickers near 0
     right at the knee (shallow queue cap = 3, 500ms deadline) and only becomes a stable signal
     64.4s *after* the true knee, deep into severe overload. **Do not conclude "no overload" from a
     flat `queue_depth` reading alone.**
   - Token-arrival rate and CPU-utilization both fired 34-38s *too early* (false positives) in the
     same measured run — **never use either as the primary evidence that a regression is
     load-related.**
5. **If a live re-measurement against a known reference is warranted**, reuse an *existing* seeded
   workload at the *same* rate/seed as a prior evidence run (e.g.
   `experiments/autoscaling/workloads/signal-comparison-ramp.json`,
   `scaling-demo-sustained.json`) rather than an ad hoc heavier load — this is the same method
   IO-T009 §4.1 used for its own cross-environment replication (three independent re-measurements
   landing within 1-13% of the reference). **Operational caveat:** this step itself drives real
   load against the stack; schedule it deliberately, not casually during an active incident on a
   shared/resource-constrained environment — this is exactly why this runbook's own walkthrough
   (below) is a tabletop trace of the method rather than a fresh load run performed just to write
   this document.

## Mitigation

- **Confirmed capacity regression, no correlated digest/config change:** genuine capacity
  shortfall → hand off to `capacity-shortfall.md` (scale out).
- **Correlated digest change:** use `rollback.md`.
- **Correlated config change:** use `config-rollback.md`.
- **Confirmed observability-path artifact:** use `observability-outage.md`; do not chase a
  performance regression that is actually a monitoring gap.

## SRE overload/cascading-failures lens

- **Do not diagnose overload using CPU utilization alone.** IO-T009 measured it firing 34-38s
  early (false positive) on this stack, and — stated honestly — this mock/CPU substrate does no
  real inference math, so much of that signal is scheduler/network noise rather than genuine
  load-proportional work. Use `in_flight`/`queue_depth` (with the lag caveat above) and goodput
  directly instead.
- **A capacity shortfall that is shedding correctly (typed 503 + `Retry-After`, admitted-request
  latency protected) is a controlled degradation, not a cascading failure** — do not treat it with
  the same urgency as an untyped/hung failure. Reserve escalation urgency for cases where admitted-
  request latency itself is degrading, or shedding is silent/untyped.
- **Never loosen admission caps as a quick fix without addressing the root cause.** The
  shallow-queue admission profile exists specifically to protect accepted-request latency;
  widening it trades shedding for widespread latency degradation across the whole admitted
  population — the opposite of what the overload lens recommends. If capacity genuinely needs to
  grow, scale out (`capacity-shortfall.md`) or get a revised Contract 7 recommendation from
  fleetlab; don't turn an admission knob ad hoc mid-incident.

## Verification

- After mitigation, golden dashboard TTFT/ITL/E2E panels return to the established baseline.
- Goodput at the known reference offered rate matches within the historically observed
  cross-environment replication spread (this repo's own measurements landed within +1.3% to +12.8%
  of the fleetlab-fitted reference depending on operating point — treat a result far outside that
  band as still-regressed, not as noise).

## Escalation

If the regression persists after ruling out digest, config, and observability-path causes, and a
capacity scale-out does not relieve it, escalate as a possible engine/gateway-level defect —
open an issue upstream citing the reference corpus numbers (`experiments/autoscaling/results.md`)
as the quantified baseline the regression is measured against.

## Walkthrough

**Tabletop.** No live performance-regression incident exists in this repo's evidence to cite
end-to-end — IO-T009's experiments establish the reference corpus and the signal-detection
comparison this runbook's diagnosis steps are built on, but that work was a controlled experiment,
not a regression response. This runbook's diagnosis flow is traced step-by-step against: (a)
`experiments/autoscaling/results.md` §2.2's measured signal-lag/lead numbers, (b) fault scenario
6's admission-protection finding (admitted latency stays near baseline even at 98% shed), and (c)
the reference latency/goodput numbers themselves. It has not been independently exercised as a
live "diagnose an actual regression" run in this session. Stated honestly as a gap in
`runbooks/README.md`.
