# ADR-0003 — KEDA not adopted for IO-T009 autoscaling experiments

- **Status:** Accepted (decided during IO-T009 implementation, 2026-07-12)
- **Date:** 2026-07-12
- **Deciders:** inferops maintainer

## Context

IO-T009 requires an HPA baseline (CPU-based, the naive mechanism) and admits
KEDA "only if a required signal cannot be served otherwise" (`docs/tasks.md`,
`docs/experiments.md` §2), with a justifying ADR required *before* adoption —
never adopted by default. fleetlab's FL-T006 signal comparison
(`/home/user/fleetlab/reports/autoscaling-signals.md`) and the FL-T009
Contract 7 recommendation for this exact workload class
(`examples/recommendations/e2-admission-sane-v1-5x-scaleout.capacity-recommendation.json`)
both name `inference_queue_depth` — a Contract 2 canonical gateway metric,
not a Kubernetes built-in resource metric — as the recommended (fallback)
autoscaling signal. Standard Kubernetes HPA only scales natively on CPU/
memory `Resource` metrics; scaling on an arbitrary Prometheus gauge like
`inference_queue_depth` requires either:

1. A `metrics.k8s.io`/`external.metrics.k8s.io` adapter (e.g.
   `k8s-prometheus-adapter`) feeding a plain `autoscaling/v2` HPA an
   `External`/`Pods` metric, or
2. KEDA's `ScaledObject` CRD + its own Prometheus scaler, which wraps (1) in
   a purpose-built operator and CRD surface.

## Decision

**Do not adopt KEDA (or a standalone Prometheus Adapter) in this repo, at
this task.** The CPU-based `autoscaling/v2` HPA
(`deploy/infergate/base/hpa.yaml`) is the only Kubernetes autoscaling object
this repo ships. The queue-depth-signal experiment and the compose-scaling
demonstration (`experiments/autoscaling/`) are run entirely on the compose
substrate instead, per the RQ-14 compose-pivot
(`docs/implementation-notes.md` Deviations D-1): this build environment
cannot schedule any pod at all (proven at the runc/nsexec level,
`/home/user/tools/k8s-env-probe-report.md`), so **no controller loop of any
kind — plain HPA, Prometheus-Adapter-backed HPA, or KEDA — can actually
evaluate a metric and trigger a real scheduling decision here regardless of
which one is installed.** Standing up either adapter would add real
deployment surface (an operator, a CRD, RBAC, a running Prometheus-query
loop) whose only possible output in this environment is an unevaluated
Kubernetes object next to the unevaluated plain-CPU HPA already authored —
zero additional evidence value over what a code comment already states.

The actual "which signal should trigger scaling" question is answered
empirically instead, by driving real load against the running compose
gateway and reading real Prometheus series
(`experiments/autoscaling/report.md` §2) — this produces stronger evidence
(measured signal behavior under a real load ramp) than an installed-but-never
-evaluated ScaledObject would have.

## Re-entry condition

If this environment (or a follow-on session) gains real pod-scheduling
capability (the D-1 follow-up: `CAP_SYS_RESOURCE` restored, or a cluster
target outside this sandbox), KEDA becomes worth revisiting **only if** the
compose-substrate signal comparison (this task) confirms `inference_queue_depth`
or `predicted_goodput_deficit`-style reasoning materially outperforms CPU
utilization for this workload class (consistent with fleetlab's finding) —
at that point a `ScaledObject` with a Prometheus trigger on
`inference_queue_depth` is the smaller-footprint of the two adapter options
(no separate `external.metrics.k8s.io` API server to run), and the ADR to
write then is "KEDA ScaledObject for queue-depth scaling," not this one.
Until real scheduling exists, adopting either adapter is pure YAML with no
evidence value — exactly the R7 risk (`docs/risks.md`) this program's ADR
discipline exists to prevent.

## Consequences

**Positive:** zero added operator/CRD/RBAC surface; the CPU HPA baseline
still exists and is validated against a live k3s API server
(`clusters/local/evidence/k3s-validation-20260712-hpa.txt`); the
queue-depth-vs-CPU comparison is answered with real measured data instead of
an unevaluated object.

**Negative / accepted cost:** this repo does not demonstrate a live
Kubernetes custom/external-metrics HPA wired end-to-end — that remains
future work, gated on real pod scheduling becoming available (see D-1's own
follow-up note).
