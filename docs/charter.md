# Charter — inferops

## Mission

`inferops` is the **only** Kubernetes deployment, observability-deployment, failure-testing, and runbook repository of the `inference-systems` portfolio. It deploys **released images pinned by digest** per the deployment contract — it never checks out component source. Its job is to prove, with captured evidence, that the inference stack can be operated correctly: honest readiness during model warm-up, graceful drain, zero-error rolling updates, dashboards keyed to a published metrics vocabulary, a repeatable 12-scenario failure campaign, and verified runbooks.

## Program context

The `inference-systems` portfolio is six independent, composable repositories forming one production-grade LLM inference-serving platform:

| Repo | Role |
|---|---|
| `serving-contracts` | versioned specs/schemas — no runtime logic |
| `infergate` | the only inference gateway (Go) |
| `inferbench` | the only load-generation + benchmark-analysis system (Go + Python) |
| `fleetlab` | explainable capacity/autoscaling/cost/placement simulation (Python) |
| **`inferops`** | **this repo — Kubernetes operations, observability deployment, chaos, runbooks** |
| `inference-lab` | integration evidence, demos, portfolio narrative, OSS log |

Repositories integrate only through versioned contracts, released artifacts, result files, or documented network protocols. The dependency graph is acyclic; no shared application library exists between repos.

## Target positioning (verbatim program goal)

> Senior Backend / Platform Engineer capable of designing, building, benchmarking, operating, and reasoning about production-grade distributed AI inference infrastructure, with particular strength in streaming correctness, backpressure, scheduling boundaries, observability, capacity planning, reliability, and infrastructure orchestration.

`inferops` supplies the "Kubernetes operations → failure campaigns" links of that story: correct request path → inference gateway → reproducible engine benchmarks → **Kubernetes operations** → capacity and autoscaling decisions → **failure campaigns** → open-source contribution.

## Independent value

A reference Kubernetes inference-ops stack deployable with released public images, useful to anyone operating LLM inference on Kubernetes without any other portfolio repo:

- Honest probes for slow-warming model servers (readiness false until the engine can actually serve; liveness never kills a warming pod).
- Dashboards as code keyed to a published metrics vocabulary (Contract 2), with exemplars linking histograms to traces.
- Repeatable, scripted fault-injection for 12 contract-defined failure scenarios, adjudicated hypothesis-first.
- 10 operational runbooks, each verified by tabletop or live walkthrough.
- A documented, reproducible GPU-node profile (device plugin, resource limits, labels/taints, driver/CUDA recording).

## Integration value

- **Owns integration milestone I5** (the operational stack): `inferops → infergate → vLLM → OTel/Prometheus/Grafana/Tempo` on a local cluster + GPU node, from released images only.
- **Executes the I7 failure campaign**: all 12 contract fault scenarios injected, observed, and adjudicated; client impact measured by running `inferbench` against the cluster.
- **Verification arm of I6** (capacity feedback): applies fleetlab capacity recommendations as deployment changes and autoscaling experiments, measures the outcome, and reports observed-vs-predicted. The capacity logic itself stays in `fleetlab`.

## Operating principles

1. **Evidence over manifests.** Every task's stop condition is an evidence artifact (smoke output, test log, campaign verdict, walkthrough notes) — never a manifest count. This is the direct mitigation of the repo's headline risk R7 ("YAML exercise").
2. **Released artifacts only.** No component source checkout, ever. A deployment that cannot be built from the deployment-contract descriptor is a contract defect to file, not a local workaround.
3. **Smallest justified tooling.** See ADR-0001 (`docs/adr/0001-deployment-tooling.md`): Kustomize + raw manifests; Helm only on a proven templating need; no Argo CD or Terraform in the baseline.
4. **GPU-free by default.** Everything except IO-T005 and GPU variants runs on a CPU-only kind cluster with the mock backend and llama.cpp.
5. **Honest accounting.** Numbers carry provenance (measured / source-reported / assumed) and a date; deviations are recorded in `docs/implementation-notes.md`, never silently absorbed.
