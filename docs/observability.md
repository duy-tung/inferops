# Observability — inferops

Dashboards as code, keyed to the **exact** Contract 2 metric names. Grafana click-ops edits that are not exported back to git do not exist as evidence.

## 1. Stack

| Component | Role |
|---|---|
| OTel Collector | receives OTLP traces from the gateway; forwards to Tempo; (optionally) scrapes/forwards metrics |
| Prometheus | scrapes gateway + engine `/metrics`; stores exemplars |
| Grafana | dashboards as code (JSON committed under `dashboards/`); Tempo + Prometheus datasources |
| Tempo | trace storage; target of exemplar links |

The stack is **off the request path**: its outage must not affect serving (hypothesis H4; verified in the observability-outage runbook walkthrough by killing the collector and observing an unchanged gateway success rate).

## 2. Metric vocabulary (Contract 2 — names are normative)

Dashboards, alerts, and autoscaling signals use only these names; inventing parallel names is a defect:

| Metric | Type | Labels |
|---|---|---|
| `inference_requests_total` | counter | `model`, `backend`, `tenant_tier`, `status_class`, `error_class` |
| `inference_requests_in_flight` | gauge | `backend` |
| `inference_queue_depth` | gauge | `tenant_tier` |
| `inference_queue_wait_seconds` | histogram | `tenant_tier` |
| `inference_ttft_seconds` | histogram | `model`, `backend` |
| `inference_itl_seconds` | histogram | `model`, `backend` |
| `inference_e2e_duration_seconds` | histogram | `model`, `backend`, `status_class` |
| `inference_sheds_total` | counter | `reason` |
| `inference_retries_total` | counter | `stage` (always pre-first-token) |
| `inference_backend_healthy` | gauge | `backend` |
| `inference_usage_tokens_total` | counter | `direction`, `model`, `tenant_tier` |

**Cardinality policy:** forbidden labels — request IDs, raw tenant/user IDs, prompts, arbitrary strings. Relabeling in scrape configs must not introduce forbidden-cardinality labels (explicit review item in IO-T003). Per-request detail lives in traces.

**Measurement points (normative, for panel titles/tooltips):** TTFT = first upstream body byte at the gateway; ITL = inter-chunk gap; queue wait = admission-enqueue to dispatch.

## 3. Golden dashboard (IO-T003 deliverable)

One dashboard covering, with the exact metric names above:

1. Request rate and status — `rate(inference_requests_total[…])` by `status_class` / `error_class`.
2. Queue depth + queue wait — `inference_queue_depth` by `tenant_tier`; `inference_queue_wait_seconds` histogram quantiles.
3. TTFT / ITL / E2E latency histograms — `inference_ttft_seconds`, `inference_itl_seconds`, `inference_e2e_duration_seconds` (exemplar-enabled panels).
4. Sheds by reason — `rate(inference_sheds_total[…])` by `reason`.
5. Retries by stage — `rate(inference_retries_total[…])` (stage is always pre-first-token; a nonzero mid-stream stage would be a contract violation worth alerting on in review).
6. Backend health — `inference_backend_healthy` by `backend`.
7. Token throughput — `rate(inference_usage_tokens_total[…])` by `direction`.

Acceptance (M3): the golden dashboard renders from a live test stream, and an exemplar click on a latency histogram panel opens the corresponding Tempo trace.

## 4. Exemplar wiring (end-to-end requirement)

- Gateway emits exemplars on latency histograms (infergate's side, per Contract 2).
- Prometheus runs with exemplar storage enabled; scrape configs preserve exemplars.
- Grafana histogram panels enable exemplar display; the exemplar's trace ID links to the Tempo datasource.
- Verification: click-through demonstrated and captured for M3 evidence.

## 5. Traces

- Attributes: OTel GenAI semantic conventions at a **pinned version** (status "Development" as of 2026-07 — the pin is mandatory and recorded here when set) plus platform attributes `inference.config_version`, `inference.tenant_tier`, `inference.backend`, `inference.request_id`.
- Expected gateway span sequence, visible in Tempo: `recv → queue.wait → upstream.connect → ttft → stream.relay → settle`.

## 6. Engine scraping (Contract 4 driven)

Engine metrics endpoints and metric-name mappings come from backend-capability descriptors. vLLM waiting/KV-usage gauge names vary by version — **mapped via the descriptor, never hardcoded** (as of 2026-07 — re-verify via `curl /metrics` at session start). Scrape configs are generated/parameterized per descriptor, so an engine version bump is a descriptor + pin change, not a config hunt.

## 7. Alert sketches (documented, not paged)

| Alert | Expression sketch | Rationale |
|---|---|---|
| Backend unhealthy | `inference_backend_healthy == 0` for sustained window | routing should shift (scenario 10); sustained zero means no failover target |
| Shed-rate spike | `rate(inference_sheds_total[5m])` above threshold | admission control engaged; check saturation (scenario 6) |
| Queue-depth sustained growth | `inference_queue_depth` increasing over a sustained window | arrival > service rate; capacity shortfall runbook |
| Readiness flapping | readiness transitions per pod above threshold | probe misconfiguration or warm-up dishonesty (scenario 11 territory) |

## 8. Network exposure

All `/metrics` endpoints and Grafana/Prometheus/Tempo UIs stay in-cluster (ClusterIP; port-forward for the operator). See `docs/security.md`.
