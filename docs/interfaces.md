# Interfaces — inferops

All integration happens through the pinned `serving-contracts` bundle, released artifacts, or files. Normative schemas live in the bundle; this document summarizes what inferops consumes and how.

## Pinned contract bundle

- **Bundle:** `serving-contracts`, pinned by SemVer tag. **Current pin: `v0.2.0` (commit `484b449`)**, set at IO-T002 (2026-07-11) — matches infergate v0.1.0's own re-pin (RELEASES.md). Contains the deployment-contract and fault-scenario schemas (SC-T006) used from this task onward. CI validates against the bundle's golden fixtures (`scripts/smoke.sh` runs `kit/contracts-validate.py selftest` every invocation).
- Pre-1.0 rule: during `v0.x`, MINOR may break with an explicit migration note. Every bundle bump re-runs the contract-fixture smoke test.

## Contracts consumed

### Contract 5 — Deployment (primary contract for this repo)

Per released component, the descriptor specifies: image + digest; ports (API, metrics); environment variables and config mounts; startup/readiness/liveness semantics including warm-up-aware readiness (readiness false during model load/warm-up); model mount path and expected volume; resource requests/limits including GPU count; graceful termination (`preStop` drain hook, `terminationGracePeriodSeconds` strictly greater than the maximum stream duration); secret expectations.

**Usage rule:** manifests must be *derivable* from the descriptor. A manifest that contradicts the descriptor is a defect in one of them — file it, never silently fix locally.

### Contract 6 — Fault scenarios (I7 vocabulary)

Each of the 12 scenarios carries: ID, injection description, expected gateway semantics, expected client-visible behavior, metrics that must move, abort condition. inferops **injects and adjudicates**; infergate implements the semantics. The scenario table (with expected gateway semantics) is reproduced in `docs/experiments.md`; hypothesis documents quote the pinned schema verbatim.

### Contract 2 — Metrics and trace vocabulary

Dashboards, alerts, and autoscaling signals key on the exact canonical names:

`inference_requests_total` · `inference_requests_in_flight` · `inference_queue_depth` · `inference_queue_wait_seconds` · `inference_ttft_seconds` · `inference_itl_seconds` · `inference_e2e_duration_seconds` · `inference_sheds_total` · `inference_retries_total` · `inference_backend_healthy` · `inference_usage_tokens_total`

Cardinality policy: forbidden labels are request IDs, raw tenant/user IDs, prompts, arbitrary strings; per-request detail lives in traces; exemplars link histograms to traces. Trace attributes follow OTel GenAI semantic conventions at a pinned version (status "Development" as of 2026-07 — the pin is mandatory) plus platform attributes (`inference.config_version`, `inference.tenant_tier`, `inference.backend`, `inference.request_id`). Gateway span sequence: `recv → queue.wait → upstream.connect → ttft → stream.relay → settle`. See `docs/observability.md`.

### Contract 4 — Backend capability (probe/scrape configuration input)

Per engine: metrics endpoint + metric-name mapping (vLLM waiting/KV-usage gauge names vary by version — **mapped, never hardcoded**; as of 2026-07, re-verify via `curl /metrics` at session start), cancellation observability, context limits, concurrency hints. inferops uses these descriptors to configure Prometheus scrapes and health probes for engine pods.

### Contract 1 — Inference API (smoke-test surface only)

`POST /v1/chat/completions` (stream + non-stream), `GET /v1/models`, `/healthz`, `/readyz`, `/metrics`; SSE with `data:` events and terminal `data: [DONE]`; error envelope `{"error": {"message","type","code","param"}}` + request ID. inferops smoke tests validate the **in-cluster** gateway against the bundle's golden fixtures — inferops does not define or extend the API. The gateway admin surface (`/admin/v1/...`) is NOT part of the shared contract and must never be exposed outside the cluster.

### Contract 7 — Capacity recommendation (fleetlab → inferops, files)

Fields: input references (benchmark-result IDs, workload version, SLO, cost profile, hardware profiles); recommended topology (replica counts per hardware type, engine config); predicted goodput/latency/cost with stated uncertainty; autoscaling signal + threshold recommendation; assumptions and sensitivity notes. inferops **applies** a recommendation as a deployment change and records observed outcomes — it never edits the prediction.

## Artifacts consumed (non-contract)

| Provider | Artifact | Mechanism |
|---|---|---|
| infergate | gateway image + mock-backend image | released container **images by digest** + deployment-contract descriptor per release |
| inferbench | load generator | released binary/image, run against the cluster for client-impact measurement and seeded experiment load |
| fleetlab | capacity recommendation documents | schema-conformant **files** (Contract 7), experiment input for I6 |

## Artifacts provided

| Consumer | Artifact | Mechanism |
|---|---|---|
| inference-lab | manifests, dashboard/config bundles, campaign logs, runbooks, smoke outputs, GPU-node profile records | inferops git tags (released config bundles) + committed evidence files |

## Version pinning (recorded in manifests and the inference-lab pins file)

- Contract bundle by SemVer tag.
- infergate + mock images by **digest** + tag.
- Engine versions: vLLM v0.24.x baseline minor + exact commit, llama.cpp commit (as of 2026-07 — re-verify).
- Model checkpoint revision + quantization + tokenizer.
- Driver/CUDA recorded per GPU-node profile.
- Dashboards/collector configs released as an inferops tag.
- On every infergate image release: bump digest → re-run I5-level smoke → only then advance the pins file.
