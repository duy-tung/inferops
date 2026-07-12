# GPU node profile — inferops (IO-T005, GPU gate G6)

**Status: SHELL authored + validated, 2026-07-12. G6 is CLOSED this session — no GPU node was
rented.** Per this task's brief ("the GPU path is deferred (no GPU). Execute the documented
fallback") and `docs/implementation-notes.md` Deviation D-1 (extended below), the engine actually
serving traffic this session is **CPU llama.cpp** on the compose stack
(`compose/docker-compose.llamacpp.yml`), smoke-tested end-to-end
(`scripts/llamacpp-smoke.sh`, 22/22 passed). This document is the honest artifact: it records the
GPU-node-profile *shape* (manifests, scheduling metadata, the fields a real session would fill in)
without claiming a GPU session happened.

## 1. What this session did and did not do

| Requirement (docs/architecture.md §2.2 / tasks.md IO-T005) | This session |
|---|---|
| Device plugin install | **Not done.** No GPU node exists to install it on. Documented procedure below (source-reported, as of 2026-07 — re-verify at real session start). |
| `nvidia.com/gpu` resource limits on the engine Deployment | **Authored** — `clusters/gpu-node/gpu-profile-patch.yaml`, validated (§3). |
| Node labels/taints so only GPU workloads schedule | **Authored** (`nodeSelector`/`tolerations` in the same patch), validated (§3). |
| Driver + CUDA version recording | **Not applicable this session** — no node, no driver. Placeholder fields below, to be filled at real session start. |
| Written hypothesis + config manifest + auto-stop script + budget alert (program GPU-session rule) | **Not started** — this rule gates an actual GPU *session*; none was opened. The config-manifest half of that rule is satisfied in advance by `clusters/gpu-node/` (reusable when a session opens). |
| In-cluster engine serves via the gateway, readiness honest across real multi-minute warm-up | **Not applicable** — no GPU engine ran. The CPU llama.cpp path's readiness/warm-up story is IO-T004's territory (mock/llama.cpp startup-delay simulation, already proven there) and this session's own real-inference smoke (§4). |

## 2. Engine binary limitation (stated honestly)

The llama-server binary packaged into `infergate-llamacpp-engine:8f114a9`
(`scripts/build-llamacpp-image.sh`) was built **without a CUDA backend** — confirmed via
`ldd build/bin/llama-server` against the build tree at `/home/user/tools/llama.cpp/build`: only
`libggml-cpu.so` is linked; no `libggml-cuda.so` or `libggml-hip.so` exists anywhere in that build
directory. **Even if `clusters/gpu-node/`'s manifests were applied to a real GPU node, this exact
image would not use the GPU** — it would run its CPU code path regardless of the node it landed
on. A real GPU session for this engine would need either:

1. A CUDA-enabled llama.cpp rebuild (`cmake -DGGML_CUDA=ON`), keeping the same gateway wiring
   (`compose/llama-cpp/gateway-config.json`'s `backend.type: "llamacpp"` is engine-agnostic to CPU
   vs GPU builds — only the engine binary/image changes), or
2. vLLM, this repo's originally-planned GPU engine (`docs/architecture.md` §2.3), which would need
   its own adapter wiring (infergate's IG-T014, per `docs/tasks.md`'s IO-T005 dependency list) —
   not built or evidenced in this program as of this session.

The GPU-node-profile shell below is therefore a demonstration of the **pod/node-level GPU
scheduling pattern** (device plugin resource request, node targeting, driver/CUDA recording — the
scope `docs/architecture.md` §7 assigns to inferops; batching/KV-cache/GPU kernel selection stay
engine-owned per the program's boundary rules) — independent of which specific engine binary
eventually runs on it.

## 3. The shell: manifests + validation

- `deploy/llama-cpp/base/{deployment.yaml,service.yaml,pvc.yaml,kustomization.yaml}` — the
  CPU-realistic base (matches the engine actually running in compose: same image digest, same
  `llama-server` launch args, same probes against `/health`).
- `clusters/gpu-node/gpu-profile-patch.yaml` — the GPU-node-profile SHELL layered on top via
  Kustomize `patches:` (ADR-0001's CPU-vs-GPU-overlay variation axis): `nodeSelector`
  (`inferops.dev/gpu-class: l4-24gb` — an example pool label, **as of 2026-07, re-verify against
  the actual rented provider's node labels at real session start**), a matching `toleration`
  (`nvidia.com/gpu:NoSchedule`, the common upstream convention — re-verify), and
  `resources.limits."nvidia.com/gpu": "1"` (Kubernetes "Schedule GPUs" doc: an extended resource
  belongs in `limits`; `requests` defaults to match).
- `clusters/gpu-node/{namespace.yaml,kustomization.yaml,validate-k3s.sh}` — the overlay and its
  validation script, same method as `clusters/local/validate-k3s.sh` (IO-T002): a live k3s API
  server (`--disable-agent`, no kubelet, no pod ever scheduled).

**Validation result, 2026-07-12** (`clusters/gpu-node/evidence/k3s-validation-20260712.txt`):
`kubectl kustomize` renders 4 objects (Namespace, Service, PersistentVolumeClaim, Deployment) with
0 build errors and the GPU-profile fields confirmed present in the rendered output; a real
`kubectl apply -k clusters/gpu-node` created all 4 objects in etcd; `kubectl apply
--dry-run=server` re-validated cleanly; the Deployment's ReplicaSet created exactly one Pod, which
`kubectl describe` confirms carries `Node-Selectors: inferops.dev/gpu-class=l4-24gb`,
`Tolerations: ... nvidia.com/gpu:NoSchedule op=Exists`, and
`Limits/Requests: nvidia.com/gpu: 1` **exactly as authored** — proving the patch actually applied,
not just parsed. The Pod stayed `Pending` with `Node: <none>` (`kubectl get nodes` → none
registered), proving **no scheduling decision, GPU or otherwise, was ever made** — the same
"schema/reconciliation valid, zero pods ever start" evidence shape as IO-T002/T004's CPU-path
validation. The PVC shows the same `FailedBinding: no persistent volumes available` condition as
`deploy/postgres-dev`'s (A-3, `docs/implementation-notes.md`) — expected, harmless, no storage
class installed in this minimal validation server.

## 4. What real inference evidence exists instead (CPU fallback)

- `compose/docker-compose.llamacpp.yml`: `llama-cpp` (the engine, real quantized
  `qwen2.5-1.5b-instruct-q4_k_m.gguf` model) + `gateway-llamacpp` (a dedicated infergate gateway
  instance, `-auth-mode=none -config=<file>`, selecting the released image's llamacpp-specific
  adapter — see `docs/implementation-notes.md`'s IO-T005 entry for why this requires a config-file
  gateway instance rather than the main `gateway` service's legacy flags).
- `scripts/llamacpp-smoke.sh`: 22/22 checks passed
  (`scripts/evidence/llamacpp-smoke-20260712T001737Z/`) — non-stream + streaming real completions,
  the llamacpp adapter's own normalization contract (model-alias echo, no leaked
  `timings`/`system_fingerprint`/`prompt_tokens_details`, `created` pinned across a stream), a real
  client-disconnect cancellation observed at BOTH the gateway (`error_class=canceled`,
  `cancel_point=mid_stream`) and the engine (`llama-server` log: `cancel task`, slot freed), and a
  post-cancellation request succeeding (proving the freed slot, not a leak).
- Image/model digests: see `docs/implementation-notes.md`'s IO-T005 entry (this doc does not
  duplicate them to avoid a second place they can drift out of sync).

## 5. Placeholder fields for a real GPU session (fill in at session start)

| Field | Value |
|---|---|
| Provider / instance type | *(not rented this session)* |
| GPU model + VRAM | *(target: 24 GB-class — RTX 4090 / L4 / A10, docs/architecture.md §2.2)* |
| Driver version | *(TBD — `nvidia-smi` at session start)* |
| CUDA version | *(TBD — `nvidia-smi` / `nvcc --version` at session start)* |
| NVIDIA device plugin version | *(TBD — as of 2026-07, re-verify install method; source-reported)* |
| Node label actually applied by the provider/plugin | *(TBD — replace `inferops.dev/gpu-class` in `clusters/gpu-node/gpu-profile-patch.yaml` with the real label before applying)* |
| Session hypothesis | *(written before the session, per program GPU-session rule)* |
| Auto-stop script + budget alert | *(written before the session)* |
| Teardown verification | *(run and recorded after the session)* |

## 6. Deviation record

See `docs/implementation-notes.md` Deviations, **D-1 extension (IO-T005, 2026-07-12)**: GPU node
profile authored + validated against a live k3s API server; engine runs CPU llama.cpp in compose.
Not paused for user input — this is the CPU fallback this task's own brief authorizes
("Deviation: GPU node profile authored + validated but engine runs CPU llama.cpp in compose
(extends D-1)"), so it does not meet the deviation policy's pause bar (no public-contract, ownership,
security-posture, or milestone-scope change).
