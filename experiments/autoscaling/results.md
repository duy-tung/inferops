# IO-T009 — Autoscaling experiments report

**Status: DONE (2026-07-12).** I6 verification arm. All numbers below are measured on this
session's running compose stack (a07fd2f base + this task's commits), dated 2026-07-12, with
provenance links to the evidence directories that produced them. Hypotheses were written before
each run (`experiments/autoscaling/hypotheses.md`).

**Filename deviation note:** `docs/tasks.md`'s original expected-files line names this file
`experiments/autoscaling/report.md`; it is published here as `results.md` instead (a
tooling-imposed filename constraint in this session, unrelated to project content) — recorded per
the deviation policy in `docs/implementation-notes.md`, not silently renamed.

## 0. Scope note — RQ-14, "no pod scheduling" (read this first)

This build environment cannot schedule any Kubernetes pod
(`docs/implementation-notes.md` Deviations D-1). A live HPA/KEDA controller therefore cannot
evaluate a metric or trigger a real scheduling decision here, regardless of which mechanism is
installed. Per this task's own instruction, this report applies the same compose-pivot the rest
of this repo uses:

- The **HPA manifest** (§1) is authored and validated against a live k3s API server only — no
  controller ever evaluates it.
- The **SIGNALS and the SCALING DECISION** (§2, §3) are demonstrated on the real, running compose
  substrate: real gateway/mock containers (released digests), real Prometheus scrapes, real
  `docker stats`, real inferbench load, and a real container-count change standing in for what a
  working controller would have driven a ReplicaSet to do.

These are two different, both-real forms of evidence, exactly as `docs/implementation-notes.md`
D-1 already establishes for every other IO task — neither is a simulation of the other, and
neither claim is made to be the other below.

## 1. HPA baseline (CPU-based, the naive mechanism)

`deploy/infergate/base/hpa.yaml`: `autoscaling/v2` HPA targeting `infergate-gateway`,
`minReplicas: 2` / `maxReplicas: 8`, CPU `Resource` metric at `averageUtilization: 70` (a
conventional default with no basis in this repo's own measured data — deliberately so; see §4).
Scale-up/scale-down stabilization windows (60s / 300s) are set to match FL-T009's own recommended
`queue_depth` thresholds so the two mechanisms' *timing* is comparable even though their *signal*
differs.

**k3s validation** (`clusters/local/evidence/k3s-validation-20260712-hpa.txt`): `kubectl kustomize
clusters/local` renders 10 objects (0 build errors, up from 9 before this task);
`kubectl apply -k clusters/local` against a live (server-only, `--disable-agent`) k3s API server
creates `horizontalpodautoscaler.autoscaling/infergate-gateway`; `kubectl get hpa` confirms:

```
NAME                REFERENCE                      TARGETS              MINPODS   MAXPODS   REPLICAS
infergate-gateway   Deployment/infergate-gateway   cpu: <unknown>/70%   2         8         0
```

`TARGETS: cpu: <unknown>/70%` is expected and correct — no metrics-server runs in this validation
(disabled in every other manifest validation in this repo for the same reason), so the object is
schema-valid and reconciles against etcd but is never evaluated. `kubectl apply --dry-run=server`
re-confirms server-side admission cleanly.

**KEDA:** evaluated and **not adopted** — `docs/adr/0003-keda-not-adopted.md`. Summary: the
Contract-7-recommended `inference_queue_depth` signal is not a Kubernetes built-in resource
metric, so scaling on it for real would need a Prometheus Adapter or a KEDA `ScaledObject`. Since
*no* controller of any kind can evaluate anything in this environment (RQ-14), standing up either
adapter would add real operator/CRD/RBAC surface with zero additional evidence value over the
already-authored CPU HPA plus the real signal/scaling evidence in §2-§3 below. Re-entry condition
recorded in the ADR.

## 2. Signal-comparison experiment (H-AS-1) — the real deliverable

**Setup:** a single gateway replica running the **exact `admission-sane-v1` configuration
inferbench's own IB-T010 E2 experiment used** (`-admission-tenant-queue-cap=3
-admission-global-inflight-budget=6 -admission-global-queue-cap=3 -admission-queue-deadline=500ms`,
mock backend `-ttft=80ms -itl=10ms`) — chosen deliberately so this run's results are directly,
apples-to-apples comparable to fleetlab's FL-T009 fitted capacity claim (§4), not just a
freestanding number. Workload: `experiments/autoscaling/workloads/signal-comparison-ramp.json`
(seed `20260712101`), a 210s, 5-phase open-loop-Poisson ramp whose phase-3 and phase-4 rates
(37.8072 rps, 189.0362 rps) are IB-T010 E2's own declared baseline/overload rates verbatim.
Signals captured from **real Prometheus** (1s scrape interval on this target,
`compose/prometheus/prometheus.yml`) and **real `docker stats`** every 1s throughout, via
`experiments/autoscaling/poll_signals.py`.

Script: `experiments/autoscaling/run-signal-comparison.sh`. Evidence:
`experiments/autoscaling/evidence/signal-comparison-20260712T022504Z/` (`signals.csv`, 113 rows;
`inferbench-run/events.jsonl`, 6736 client-observed requests; `summary.md`/`summary.json`,
computed by `experiments/autoscaling/analyze_signal_comparison.py`).

### 2.1 Per-phase measured behavior

| Phase | Offered rps (planned) | Offered rps (client-observed) | Goodput rps (client-observed) | Shed frac | `queue_depth` mean/max | `in_flight` mean/max | `token_rate_out` mean | CPU% (gw) mean/max |
|---|---|---|---|---|---|---|---|---|
| 1 quiet (~24% capacity) | 8 | 8.2 | 8.2 | 0.0 | 0.0 / 0.0 | 1.04 / 3.0 | 55.97 | 3.09 / 5.44 |
| 2 approaching (~60%) | 20 | 20.76 | 20.58 | 0.0086 | 0.0 / 0.0 | 2.96 / 6.0 | 153.95 | 7.49 / 9.76 |
| 3 at ~1x (IB-T010 E2 baseline rate) | 37.8072 | 39.25 | **33.58** | 0.1444 | 0.97 / 3.0 | 5.47 / 6.0 | 259.56 | 10.35 / 14.68 |
| 4 5x severe overload (IB-T010 E2 overload rate) | 189.0362 | 181.0 | **37.40** | 0.7934 | 2.71 / 3.0 | 6.0 / 6.0 | 296.97 | 14.22 / 16.67 |
| 5 cool-down | 8 | 8.07 | 8.07 | 0.0 | 0.13 / 3.0 | 1.44 / 6.0 | 92.99 | 3.09 / 5.34 |

### 2.2 Detection — which signal fires correctly/early/stably

Detection rule reuses fleetlab's own disclosed, non-fitted procedure (FL-T006 ADR-0003: threshold
= quiet-phase (phase 1) mean + 3·std, 5s sustained to fire, drop to ≤0.7× for 5s to clear) applied
to **our own measured data** — this is observational-analysis methodology reused for fairness, not
a capacity model (`experiments/autoscaling/analyze_signal_comparison.py`).

| Signal | Calib. threshold | First fire (elapsed s) | Lag vs. true knee onset (90s) | Fired *before* the knee (false/early)? |
|---|---|---|---|---|
| `inference_queue_depth` | 0.0 | 154.4 | **+64.4s** | No |
| `inference_requests_in_flight` | 3.91 | 96.1 | **+6.1s** | No |
| token-arrival rate (`inference_usage_tokens_total` rate) | 111.98 | 55.9 | −34.1s | **Yes** |
| CPU utilization (docker-stats proxy, gateway) | 5.92% | 51.9 | −38.1s | **Yes** |
| CPU utilization (docker-stats proxy, mock backend) | 5.92% | 51.9 | −38.1s | **Yes** |

### 2.3 Verdict

**`inference_requests_in_flight` won this comparison decisively**: it fired 6.1s after the true
1x-capacity knee, with zero false/early triggers during the sub-capacity phases 1-2. It is the
clear best of the five candidate signals actually measured here.

**`inference_queue_depth` under-read the true overload, exactly as FL-T009 disclosed it would.**
Its per-phase *mean* was already nonzero at the knee (0.97 at phase 3), but the debounce-sustained
detector didn't fire until 154s — deep into the *severe* overload phase, 64.4s late. Root cause,
visible directly in the raw samples: this config's queue is genuinely shallow (cap 3, 500ms
deadline) and sheds rather than queues, so `queue_depth` *flickers* between 0 and a few at the
knee rather than holding a stable elevated reading — it only becomes a *stable* (5-second-sustained)
signal once the system is deep enough in overload that the queue is essentially always at its cap.
This sharpens FL-T009's own caveat ("`queue_depth` under-reads true overload once admission control
starts shedding instead of queuing") from a magnitude problem into a **stability** problem at
exactly the operating point where an autoscaler would need to react.

**Token-arrival rate and the CPU-utilization proxy both fired early — for different, instructive
reasons.** Token-arrival rate fired during phase 2 (still under capacity) because — exactly as
FL-T006 §8 predicts — this workload's output-length distribution is constant over time, so the
signal is just a rescaled version of the offered-rate ramp itself, not an overload indicator.

**The CPU-utilization proxy failed in the *opposite* direction from FL-T006's simulated proxy, and
is honestly a weaker signal here than FL-T006's own.** FL-T006 found utilization's uniformly-tuned
threshold *unreachable* (>1.0, discretized 2-slot occupancy) or pinned near its 1.0 ceiling well
before saturation. This report's CPU signal is `docker stats` percent-of-host-CPU for the gateway/
mock containers — no configured request/limit, and (honesty note, as instructed) **not driving any
real inference computation** (the mock backend simulates timing, it does no real model math), so
almost all of its signal is scheduler/goroutine/network noise rather than genuine load-proportional
work. Its calibration threshold (5.92%) is low and noisy enough that ordinary ramp-up traffic
(phase 2, still 60% of capacity) crossed it 38s before the true knee — a **false-early** trigger, not
an unreachable one. Both failure modes converge on FL-T006's recommendation: **do not use CPU
utilization alone as a scale-out trigger**, confirmed here by a second, independently-broken
mechanism rather than a replication of the same one.

**Confirms fleetlab's core claim.** fleetlab's FL-T006 recommendation — primary
`predicted_goodput_deficit`, fallback `queue_depth`/`in_flight_requests`, never utilization alone —
is **confirmed** by this real run, with one refinement worth carrying back: between the two
fallback signals FL-T006 groups together, **`in_flight_requests` clearly outperformed
`queue_depth`** for this exact admission-sane-v1 (shallow-queue) configuration. FL-T009's own
recommendation JSON names `inference_queue_depth` specifically (because it's the Contract-2
canonical name most directly analogous to fleetlab's simulated signal); this report's measured
result is a concrete reason a follow-up recommendation revision might prefer
`inference_requests_in_flight` for admission configs with a shallow queue cap.

## 3. Scaling demonstration (H-AS-2) — compose-scaling, not HPA pod rescheduling

**Setup:** identical admission-sane-v1 gateway config as §2. `BEFORE`: 1 replica takes
`experiments/autoscaling/workloads/scaling-demo-sustained.json` (seed `20260712102`, 50 rps
sustained, 60s) directly. **Scaling event:** a second replica (`gateway-signals-2` +
`mock-signals-2`) is brought up and both are put behind `haproxy-signals`
(`experiments/autoscaling/haproxy-signals.cfg`) — measured wall time 3s from start to both targets
ready and haproxy healthy. `AFTER`: the **identical seeded workload** is re-run against the
haproxy VIP. Script: `experiments/autoscaling/run-scaling-demo.sh`. Evidence:
`experiments/autoscaling/evidence/scaling-demo-20260712T022944Z/`.

| | BEFORE (1 replica) | AFTER (2 replicas) |
|---|---|---|
| offered rps (client-observed) | 49.93 | 49.96 |
| **goodput rps** | **36.71** | **49.96** |
| shed fraction | **26.48%** | **0.00%** |
| `queue_depth` mean / max (poller) | **1.33** / 3.0 | **0.11** / 1.0 |
| `in_flight` mean / max (poller, summed across replicas) | 4.94 / 6.0 | 6.91 / 12.0 |

**The signal-drop + goodput-recover story the task asked for, observed directly:** `queue_depth`
dropped 91% (1.33 → 0.11) and shed fraction dropped from 26.5% to 0% the moment the second replica
joined — a real before/after on the compose substrate, RQ-14-labeled throughout (this is a
container-count change, not a scheduled Kubernetes rollout).

**Honesty note — this particular 50 rps demand was below 2-replica capacity.** 0% shed after
scaling means the `AFTER` run was **demand-capped, not capacity-capped**: it proves recovery at
this specific offered rate, but it cannot by itself test whether 2-replica *capacity* scales
linearly from 1-replica capacity, because the system was never pushed hard enough post-scaling to
find its new ceiling. A naive linear read (2 × 36.71 = 73.41 predicted vs. 49.96 observed, "−31.9%")
would be a **false, artifact-driven finding** if reported without this caveat — it is not evidence
against linear scaling, only evidence that 50 rps didn't reach the 2-replica ceiling. A follow-up
run closes this gap (§4.2).

## 4. Fleetlab-prediction-vs-observed comparison — the central ask

### 4.1 Single-replica capacity: does it match FL-T009's fitted 33.159 rps?

FL-T009's recommendation (`examples/recommendations/e2-admission-sane-v1-5x-scaleout.capacity-recommendation.json`)
fits its one-parameter capacity model directly from inferbench's own real
`ib-t010-e2-baseline-1x-sane` measurement: **33.159 rps** achieved at 37.8072 rps offered
(`reports/holdout-validation.md` §2a). A second, independent measurement exists in the same
evidence (the "5x" overload point): **37.925 rps** achieved at 189.0362 rps offered — the
**overload-empirical** estimate, whose gap from the baseline-fit estimate (−12.6%/+14.0%
depending on direction) is `holdout-validation.md`'s own documented, unresolved model-specification
limitation (real capacity has some dependence on offered load itself; a one-parameter model can't
capture that with only 2 real points per config).

This task ran the **same config, same rates, on this repo's own compose stack** (a different host,
independently reproducing the setup rather than reusing inferbench's numbers) three separate times:

| Measurement | Offered rps | Duration | Goodput rps (measured here) | vs. fleetlab's 33.159 (baseline-fit) | vs. inferbench's 37.925 (overload-empirical) |
|---|---|---|---|---|---|
| Signal-comparison phase 3 | 37.8072 (exact IB-T010 E2 baseline rate) | 60s | **33.58** | **+1.3%** | −11.5% |
| Signal-comparison phase 4 | 189.0362 (exact IB-T010 E2 overload rate) | 15s | **37.40** | +12.8% | **−1.4%** |
| Scaling-demo BEFORE | 50 (1.5x baseline rate, a third independent point) | 60s | **36.71** | +10.7% | **−3.2%** |

**Verdict: fleetlab's 33.159 rps/replica figure is confirmed at the specific offered rate it was
fitted from** (within +1.3% when this task re-runs the identical baseline rate) — a strong,
independent, cross-environment replication. **At higher offered rates, this task's own measurements
track visibly closer to inferbench's own alternative "overload-empirical" 37.925 rps estimate**
(within 1-3%, vs. 11-13% off the baseline-fit figure) — the same offered-rate-dependent-capacity
pattern `holdout-validation.md` already flagged as an open, unresolved question, now with three
more independent measured points supporting the overload-empirical side of it, not just confirming
that *some* deviation exists. **This is not a refutation of FL-T009 — 33.159 rps is the right number
at the load level it was measured at — but it is a concrete answer to which of fleetlab's own two
open single-point estimates better predicts behavior away from that exact point, and the answer
leans toward 37.925, not 33.159.**

Token throughput cross-checks the same story: phase 3's measured 259.6 output tok/s vs.
inferbench's own reported 260.4 tok/s at the identical rate (**−0.3%**); phase 4's 297.0 tok/s vs.
inferbench's 282.0 tok/s at the identical rate (**+5.3%**, same direction as the rps gap above).

### 4.2 2-replica linear-scaling check

FL-T009's recommendation explicitly discloses linear replica-scaling as an **untested assumption**
("no multi-replica benchmark exists anywhere in this program's evidence") and specifies a
`re_measurement` plan (`replica_count 1 -> 6`) to close it. This task cannot run fleetlab's full
6-replica plan (out of scope/resource budget for a compose demonstration — see §0), but ran a
genuine, saturating 2-replica capacity check as a small, honest, directional test of the same
question: `experiments/autoscaling/run-scaling-demo-2replica-capacity.sh`, workload
`workloads/scaling-demo-2replica-capacity.json` (80 rps, comfortably above 2× either single-replica
estimate), evidence `experiments/autoscaling/evidence/scaling-demo-2replica-capacity-20260712T023333Z/`.

| | Value |
|---|---|
| Offered rps (client-observed) | 79.39 |
| **Observed 2-replica goodput rps** | **72.39** |
| Shed fraction (confirms this run WAS capacity-capped, unlike §3's AFTER) | 8.81% |
| Linear 2× prediction from fleetlab's 33.159 baseline-fit | 66.32 (observed is **+9.2%** above) |
| Linear 2× prediction from inferbench's 37.925 overload-empirical | 75.85 (observed is **−4.6%** below) |

**Verdict:** the observed 2-replica ceiling (72.39 rps) lands **between** the two candidate
per-replica×2 predictions, and — consistent with §4.1 — closer to the overload-empirical-based
prediction (−4.6%) than the baseline-fit-based one (+9.2%). Linear scaling holds reasonably well at
this small scale (within ±9% either way, not a large multiplicative miss), which is itself a
meaningful, positive data point for FL-T009's explicitly-untested assumption — but this is a
2-replica result, not the 6-replica result FL-T009's `re_measurement` plan actually calls for, and
is reported as exactly that: a small, real, honest step toward closing that plan, not a
substitute for it.

### 4.3 6-replica recommendation itself

FL-T009 recommends 6 replicas to serve the 189.0362 rps "5x" demand, predicting goodput
`[165.279, 189.036]` rps. This task's compose substrate was not scaled to 6 replicas (resource/time
budget for this experiment; RQ-14 already establishes no real scheduler exists to enact 6 replicas
as pods regardless). Extrapolating (not claiming as measured) from this task's own 1- and
2-replica figures: 6 × 33.58 (this task's own phase-3 figure) = 201.5 rps, or 6 × 36.0 (average of
this task's three single-replica measurements) ≈ 216 rps — both comfortably inside or above
fleetlab's stated `[165.279, 189.036]` interval, consistent with (not contradicting) the
recommendation, but this sentence is explicitly an extrapolation from 1-2 real replicas, not a
6-replica measurement, and is labeled as such.

## 5. Deviations

- **RQ-14 (no pod scheduling)** applies throughout — see §0. Carried from D-1, not a new deviation.
- **6-replica re-measurement not run** — resource/time-scoped down to a genuine, saturating
  2-replica check (§4.2) instead of fleetlab's full 1→6 plan; recorded as a scope reduction, not a
  skip (`docs/implementation-notes.md`).
- **CPU-utilization proxy is `docker stats`, not a Kubernetes cgroup-relative utilization metric**
  — explicitly weaker/noisier than even FL-T006's own already-caveated simulated proxy (§2.3);
  stated up front rather than presented as equivalent.
- **Filename:** this file is `results.md`, not the originally-named `report.md` (see the note at
  the top of this file).

## 6. Reproduction

```bash
# HPA k3s validation
bash clusters/local/validate-k3s.sh

# Signal comparison (~4 minutes)
bash experiments/autoscaling/run-signal-comparison.sh

# Scaling demonstration (~2.5 minutes)
bash experiments/autoscaling/run-scaling-demo.sh

# 2-replica capacity follow-up (~1 minute)
bash experiments/autoscaling/run-scaling-demo-2replica-capacity.sh
```

All three experiment scripts are seeded (workload `seed` fields) and re-runnable; each creates a
fresh timestamped evidence directory under `experiments/autoscaling/evidence/` and tears its
containers down on exit.
