# IO-T009 — autoscaling experiment hypotheses (written before the runs)

Per `docs/experiments.md` §2 template:

> Scaling on **<signal>** at **<threshold>** keeps **<SLO metric>** within
> **<bound>** under seeded workload **<workload id + seed>** — as predicted
> by fleetlab report **<ID>**.

## H-AS-1 — signal comparison (experiments/autoscaling/run-signal-comparison.sh)

Scaling on **`inference_queue_depth`** at fleetlab's own recommended
threshold (**> 1 for 60s scale-out / < 1 for 300s scale-in**, from
`examples/recommendations/e2-admission-sane-v1-5x-scaleout.capacity-recommendation.json`
`autoscaling.thresholds`) detects the offered-load ramp crossing this
single-replica's admission-sane-v1 capacity knee (empirically ~33-34 rps,
matching FL-T009's fitted 33.159 rps/replica — confirmed or refuted below)
**earlier and more stably than CPU utilization** (docker-stats proxy, the
naive HPA baseline signal), consistent with fleetlab's FL-T006 recommendation
(`reports/autoscaling-signals.md`: primary `predicted_goodput_deficit`,
fallback `queue_depth`/`in_flight_requests`, utilization never alone) —
under seeded workload `experiments/autoscaling/workloads/signal-comparison-ramp.json`
(seed `20260712101`), against a single gateway replica running the exact
admission-sane-v1 configuration inferbench's own IB-T010 E2 experiment used.

**Falsifiable prediction:** `inference_queue_depth` and/or
`inference_requests_in_flight` cross a stated, data-derived threshold at or
before the true knee (phase 3 onset, offered rate 37.8072 rps ≈ 1x measured
capacity); the docker-stats CPU-utilization proxy either (a) never reaches a
uniformly-tuned threshold (mirroring FL-T006 Finding 1) or (b) pins/saturates
during phase 2 (well before the true knee), losing discriminative value
exactly where FL-T006 Finding 2 predicts. `inference_usage_tokens_total`
rate is expected to track the request-count-based signals closely (this
workload's token-length distribution is constant over time, the same scope
limit FL-T006 §8 records for `token_arrival_rate`).

## H-AS-2 — scaling demonstration (experiments/autoscaling/run-scaling-demo.sh)

Scaling gateway replicas **1 → 2** (compose-scaling, not HPA pod
rescheduling — see RQ-14 note below) under a sustained 50 rps offered load
(~1.5x the single-replica capacity measured in H-AS-1) keeps **goodput**
(achieved rps) closer to the 50 rps demand and **reduces the shed rate**
after scaling, and the **before** run's `inference_queue_depth` reading is
expected to under-read the true overload (FL-T009's own disclosed caveat
for this exact admission-sane-v1 config: shallow queue cap = 3, so excess
demand sheds rather than queueing deep) — under seeded workload
`experiments/autoscaling/workloads/scaling-demo-sustained.json` (seed
`20260712102`), run twice with the identical seed (1 replica, then 2).

**Falsifiable prediction:** 2-replica achieved rps is closer to 50 rps than
1-replica achieved rps, AND 2-replica achieved rps is *not* simply ~2x the
1-replica figure if the single-replica run was itself demand-capped rather
than capacity-capped (linear-scaling is FL-T009's own explicitly
**untested** assumption — this run is a small, honest, directional test of
it at 2 replicas, not a claim to have validated it at fleetlab's recommended
6.

## Scope note (RQ-14, "no pod scheduling")

Neither hypothesis is tested via a live Kubernetes HPA controller — this
build environment cannot schedule any pod
(`docs/implementation-notes.md` Deviations D-1). The HPA manifest
(`deploy/infergate/base/hpa.yaml`) is authored and validated against a live
k3s API server only. Both experiments above run the SIGNALS and the
SCALING DECISION on the actual running compose substrate: real gateway/mock
containers, real Prometheus scrapes, real `docker compose`-style
container-count changes standing in for what a working HPA/KEDA controller
would have done to the ReplicaSet. This is stated explicitly in every
evidence file this task produces, per the task's own instruction not to
conflate the two forms of evidence.
