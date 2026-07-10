# Architecture — inferops

## 1. Tooling decision (summary; normative record in ADR-0001)

**Kustomize + raw manifests.** Raw YAML is the source of truth; Kustomize overlays handle the only real variation axes we have (local CPU cluster vs GPU-node profile, image digest pinning, replica counts for experiments). Helm is **not** admitted — no templating need has been proven; if one emerges it must be recorded concretely in an ADR before adoption. No Argo CD (single local cluster, single operator — a GitOps controller adds surface without evidence value) and no Terraform (nothing to provision declaratively in the baseline; the rented GPU node is a documented manual profile with scripts). See `docs/adr/0001-deployment-tooling.md`.

## 2. Cluster layout

### 2.1 Base cluster (CPU-only)

- **kind** is the working choice for the local base cluster (working assumption pending the kind-vs-k3s ADR, to be written with CI evidence in IO-T002): the testing plan requires CI to spin the cluster and run smoke + lifecycle tiers, and kind is the reproducible-in-CI option. k3s would favor a persistent local node; nothing in the current requirements needs one.
- All CPU-path work runs here GPU-free: mock backend, llama.cpp (CPU), dev PostgreSQL, the full observability stack, lifecycle tests, and the fault campaign's CPU-path scenarios.

### 2.2 GPU-node profile

A documented, reproducible node setup for a rented single 24 GB-class GPU node (RTX 4090 / L4 / A10 class; source-reported spot prices as of 2026-07: 4090 ~$0.31–0.69/h, L4 ~$0.39/h — re-verify at use time):

- NVIDIA device plugin installation (as of 2026-07 — re-verify plugin version/install method at session start).
- `nvidia.com/gpu` resource limits on GPU workloads.
- Node labels and taints so only GPU workloads schedule there.
- A recording step capturing **driver + CUDA versions into the node profile document** — these are part of benchmark comparability and are pinned per node.
- Grounded in the Kubernetes "Schedule GPUs" documentation (study-track resource; produces the profile artifact, not a summary).

GPU sessions follow program rules: written hypothesis + full config manifest + auto-stop script + budget alert before the session; teardown verified; session log committed. Program GPU envelope ~$150–250 total (as of 2026-07; user-confirmable), shared across all repos. IO-T005 is this repo's only GPU task.

### 2.3 Workloads

| Workload | Kind | Notes |
|---|---|---|
| infergate | Deployment (multi-replica capable) | released image by digest; PDB; drain-correct lifecycle |
| mock backend | Deployment | released image by digest (owned by infergate, consumed as image) |
| llama.cpp | Deployment (CPU) | pinned commit (as of 2026-07 — re-verify); warm-up simulation target |
| vLLM | Deployment (GPU node) | v0.24.x baseline minor + exact commit (as of 2026-07 — re-verify); model mount per deployment contract |
| dev PostgreSQL | StatefulSet or single-replica Deployment + PVC | dev-grade only, documented as such; never exposed outside the cluster |
| observability stack | OTel Collector, Prometheus, Grafana, Tempo | off the request path; its outage must not affect serving |

## 3. Lifecycle semantics (the heart of I5)

- **Warm-up-aware readiness.** vLLM model load + warm-up takes minutes. Readiness must be honest — false until the engine can actually serve. A `startupProbe` (or equivalent long-window probe) tolerates the full warm-up; **liveness must never kill a warming pod** (fault scenario 11: "no traffic before warm; no restart loops"). Probe endpoints and semantics come from the deployment contract (Contract 5) and capability descriptors (Contract 4), never invention. On the CPU path, slow warm-up is simulated via mock/llama.cpp startup delay so the pattern is provable GPU-free.
- **Graceful shutdown.** A `preStop` drain hook flips readiness and lets accepted streams complete. `terminationGracePeriodSeconds` is **strictly greater than the maximum stream duration** — computed from gateway config, with the arithmetic recorded in the manifest's companion doc.
- **Rolling updates + disruption.** Rolling-update strategy tuned so an update under live load produces zero client-visible errors (scenario 12; program success criterion H1). PodDisruptionBudget for the gateway; disruption behavior documented.
- **Config rollout.** Gateway config changes roll out as an immutable snapshot swap (gateway-side mechanism); inferops owns the in-cluster mechanics: ConfigMap/secret versioning, rollout, and rollback procedure — exercised by scenario 8.
- **Secret strategy.** No secrets in manifests or git; see `docs/security.md`.

## 4. Observability topology

```
infergate pods ──(OTLP traces + Prometheus /metrics)──> OTel Collector ──> Tempo (traces)
engine pods   ──(/metrics per capability descriptor)──> Prometheus  <──── scrape configs
Prometheus (+ exemplar storage) ──> Grafana dashboards (as code) ──exemplar links──> Tempo
```

- Dashboards, alerts, and autoscaling signals use the **exact** Contract 2 metric names — never parallel names. Full plan in `docs/observability.md`.
- Exemplars are wired through the collector/Prometheus/Grafana path so a latency histogram panel opens the corresponding Tempo trace.
- Engine scrape configs and probe endpoints are configured from backend-capability descriptors (Contract 4); vLLM waiting/KV-usage gauge names vary by version and are **mapped, never hardcoded** (as of 2026-07 — re-verify via `curl /metrics` at session start).
- The observability stack is not on the request path: killing the collector must not change gateway request success rate (hypothesis H4; verified in the observability-outage runbook walkthrough).

## 5. Failure injection

Injection is scripted and repeatable. Per scenario: an injection script (prefer the simplest injector that produces the fault — `kubectl delete pod` at a controlled phase before tc/chaos tooling, which is admitted only with an ADR-recorded justification), an observation checklist (metrics that must move, dashboards to capture, log/trace queries), and an expected-vs-observed verdict in the campaign matrix. **Hypotheses are written before injection** (Contract 6 expected semantics + expected client-visible behavior). Client impact for streaming-critical scenarios (1, 2, 5, 6, 12) is measured by running `inferbench` (released binary/image) against the cluster during injection — never by reimplementing load generation. GPU-dependent scenarios may fall back to the llama.cpp/mock path with a recorded deviation.

## 6. Autoscaling experiments (experiments only)

HPA is the baseline mechanism. KEDA is admitted only if a required signal cannot be served by HPA + a metrics adapter — justified in an ADR before adding. Signals under test: queue depth (`inference_queue_depth`), in-flight requests (`inference_requests_in_flight`), token-arrival rate (derived from `inference_usage_tokens_total`). Each experiment: seeded inferbench load, a scaling configuration, observed scaling events, comparison against fleetlab's prediction for the same workload. **inferops never computes what capacity should be** — it deploys, drives load, observes, reports. Designs in `docs/experiments.md`.

## 7. State ownership & failure behavior

inferops owns cluster manifests, dashboards, runbooks, and fault-scenario scripts (git + released config bundles). It owns **no application state**. Failure/cancellation/retry semantics are the gateway's — Contract 6's expected-semantics column is what inferops *verifies*, not implements. GPU placement is owned only at the pod/node level (device plugin, resource limits, node labels); everything below (batching, per-token scheduling, KV-cache) is engine-owned.
