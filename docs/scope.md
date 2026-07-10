# Scope — inferops

## The released-images-only rule (prominent, non-negotiable)

> **inferops deploys RELEASED images, pinned by digest, per the deployment contract. It NEVER checks out component source.**
>
> If a deployment cannot be made to work from the released image + deployment-contract descriptor, that is a **contract gap**: file it against `serving-contracts`/`infergate` and stop — do not clone infergate, vLLM, or inferbench source, do not build component images locally, do not work around it. This rule is auditable across the entire repo history and CI (Definition of Done item 4).

Corollaries:

- No `:latest` tags; no locally built component images; every digest in a manifest must match the released artifact recorded in the inference-lab pins file.
- On every infergate image release: inferops bumps the digest and re-runs I5-level smoke evidence **before** the pins file advances.

## What inferops owns

1. **Local Kubernetes** (kind/k3s — see architecture §2.1) plus a documented **GPU-node profile** (device plugin, `nvidia.com/gpu` limits, node labels/taints, driver/CUDA recording).
2. **Deployments** for infergate, mock backend, vLLM, llama.cpp, and dev PostgreSQL — all from released images by digest, manifests derivable from the Contract 5 descriptor.
3. **Observability deployment**: OTel Collector, Prometheus, Grafana, Tempo; dashboards as code keyed to the Contract 2 metrics vocabulary; exemplar wiring.
4. **Pod lifecycle semantics**: warm-up-aware startup/readiness/liveness, `preStop` graceful drain, rolling updates, PodDisruptionBudgets, resource requests/limits, config rollout mechanics (ConfigMap/secret versioning + rollback), secret strategy.
5. **Failure injection and chaos experiments**: the 12 contract fault scenarios (Contract 6), scripted and hypothesis-first, with a campaign matrix.
6. **Autoscaling experiments** (HPA baseline; KEDA only with ADR justification): deploy, drive seeded load, observe scaling events, report observed-vs-predicted against fleetlab. Capacity **logic** stays in fleetlab.
7. **10 operational runbooks**: deploy, upgrade, rollback, drain, backend failure, performance regression, config rollback, capacity shortfall, observability outage, database outage — each verified by walkthrough.
8. **GPU placement at the pod/node level only**: device plugin, resource limits, node labels. Nothing below that level.

## What inferops explicitly does not own

See `docs/non-goals.md` for the full list. Headlines: no gateway/engine/benchmark source, no capacity math, no benchmark analysis, no second load generator or gateway shim, no engine internals (continuous batching, per-token scheduling, KV/prefix-cache).

## Artifacts provided to others

| Consumer | Artifact |
|---|---|
| inference-lab | manifests, dashboard/config bundles (released as inferops git tags), campaign logs, runbooks, smoke outputs, GPU-node profile records (driver/CUDA per node) |
| I5/I6/I7 milestones | acceptance evidence (see `docs/integration.md`) |

No repo consumes inferops as a library; dashboards/configs are released artifacts (git tags).

## Sequencing guard

Ops work must produce **evidence**, not manifests for their own sake. Ops starts only after gateway behavior is proven: the CPU baseline (IO-T002–T004) starts only after infergate has released an image (IG-T016), and IO-T005 requires infergate's I4-level evidence.
