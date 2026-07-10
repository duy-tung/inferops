# Non-goals — inferops

Explicit exclusions. Each entry names where the capability lives instead (if anywhere). Violating one of these is a review-gate failure, not a judgment call.

## 1. No capacity math

Autoscaling **experiments** run here; the signal-comparison logic, capacity models, headroom analysis, and predictions live in **fleetlab**. inferops never computes what capacity *should* be, never edits a fleetlab recommendation or its analysis, and never grows "just a little" modeling code to interpret experiment results. A wrong fleetlab prediction is a result to report, not something to correct locally.

## 2. No benchmark analysis

Statistics, percentile pooling, goodput/SLO analysis, saturation-knee detection, cost-per-request math — all **inferbench** (Python analysis side). inferops runs inferbench against the cluster and archives its outputs; it does not post-process raw events beyond what a campaign verdict requires (reading inferbench's report).

## 3. No second load generator

Client-impact measurement during fault scenarios and seeded load for autoscaling experiments is done by running **inferbench** (released binary/image). Writing even a small `hey`/`curl`-loop-grade load driver for "quick checks" that then leaks into evidence is forbidden — program hard rule 2.

## 4. No gateway shim

**infergate** is the only gateway. inferops adds no proxy, sidecar request-mangler, or traffic-shaping layer that alters inference request/response semantics. (A plain Kubernetes Service/port-forward for test access is fine; anything that touches SSE framing, retries, or errors is not.)

## 5. No component source checkouts

Released images by digest only — see the prominent rule in `docs/scope.md`. No `git clone` of infergate/vLLM/llama.cpp/inferbench anywhere in repo history or CI; no building component images from source.

## 6. No Argo CD / Terraform in the baseline

Single local cluster, single operator: a GitOps controller and cloud provisioning add surface without evidence value (ADR-0001). Revisit only on evidence, per the deviation policy.

## 7. No production multi-region

No multi-cluster federation, no multi-region failover, no global load balancing. The scope is one local CPU cluster plus one documented GPU-node profile.

## 8. No engine internals

Continuous batching, per-token scheduling, KV-cache/prefix-cache internals, and GPU placement below the pod/node level are **engine-owned** (program hard rule 4). inferops touches GPU placement only as: device plugin, `nvidia.com/gpu` limits, node labels/taints.

## 9. No brokers on the request path

No Kafka, NATS, Redis Streams, or any broker in the synchronous inference request path (program hard rule 3). inferops must not introduce one for "operational buffering" either.

## 10. No contract authoring

Schemas, the API subset, metric names, and fault-scenario definitions are owned by **serving-contracts**. inferops consumes a pinned bundle; mismatches are filed as contract defects, never patched locally (a manifest that contradicts the deployment descriptor is a defect in one of them, never a silent local fix).

## 11. No production-grade database operations

Dev PostgreSQL is dev-grade by declaration: no HA, no backup/restore SLOs, no tuning work. The database-outage runbook covers the gateway's behavior under DB failure (Contract 6 scenario 9), not PostgreSQL administration depth.

## 12. No click-ops observability

Dashboards, alerts, and scrape configs exist as code in git. Grafana UI edits that aren't exported back to the repo do not exist as far as evidence is concerned.
