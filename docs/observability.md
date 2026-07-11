# Observability — inferops

Dashboards as code, keyed to the **exact** Contract 2 metric names. Grafana click-ops edits that are not exported back to git do not exist as evidence.

## 1. Stack

| Component | Role |
|---|---|
| OTel Collector | receives OTLP traces from the gateway; forwards to Tempo; (optionally) scrapes/forwards metrics |
| Prometheus | scrapes gateway + engine `/metrics`; stores exemplars |
| Grafana | dashboards as code (JSON committed under `dashboards/`); Tempo + Prometheus datasources |
| Tempo | trace storage; target of exemplar links |

The stack is **off the request path**: its outage must not affect serving (hypothesis H4; verified in the observability-outage runbook walkthrough by killing the collector and observing an unchanged gateway success rate — IO-T008, not yet executed).

**Image pins (IO-T003, 2026-07-11 — Docker Hub/quay.io, digest-pinned, no `:latest`):**

| Component | Image | Digest |
|---|---|---|
| OTel Collector | `otel/opentelemetry-collector-contrib:0.112.0` | `sha256:2203eea06554f892c765d6eff8069cdf64ae8d4516526d03cab4a70e82775495` |
| Prometheus | `prom/prometheus:v2.55.1` | `sha256:2659f4c2ebb718e7695cb9b25ffa7d6be64db013daba13e05c875451cf51b0d3` |
| Grafana | `grafana/grafana:11.3.1` | `sha256:fa801ab6e1ae035135309580891e09f7eb94d1abdbd2106bdc288030b028158c` |
| Tempo | `grafana/tempo:2.6.1` | `sha256:ef4384fce6e8ad22b95b243d8fc165628cda655376fd50e7850536ad89d71d50` |

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

## 3. Golden dashboard (IO-T003 deliverable — `dashboards/golden-dashboard.json`)

One dashboard covering, with the exact metric names above:

1. Request rate and status — `rate(inference_requests_total[…])` by `status_class` / `error_class`.
2. **In-flight requests** by `backend` (`inference_requests_in_flight`) — added as its own panel
   at IO-T003 implementation time: this section's original 7-group sketch covered 10 of the 11
   canonical names and missed this gauge; recorded here as a doc correction, not a silent drop.
3. Queue depth + queue wait — `inference_queue_depth` by `tenant_tier`; `inference_queue_wait_seconds` histogram quantiles (p50/p95/p99).
4. TTFT / ITL / E2E latency histograms — `inference_ttft_seconds`, `inference_itl_seconds`, `inference_e2e_duration_seconds` (exemplar-enabled panels, p95).
5. Sheds by reason — `rate(inference_sheds_total[…])` by `reason`.
6. Retries by stage — `rate(inference_retries_total[…])` (stage is always pre-first-token; a nonzero mid-stream stage would be a contract violation worth alerting on in review).
7. Backend health — `inference_backend_healthy` by `backend`.
8. Token throughput — `rate(inference_usage_tokens_total[…])` by `direction`.

All 11 Contract 2 canonical names are represented on the dashboard.

**Acceptance (M3), verified 2026-07-11 (compose-pivot, `scripts/verify-observability.sh`, 16/16
checks passed — `scripts/evidence/observability-20260711T233804Z/`):** the golden dashboard's
panel queries render live data through Grafana's Prometheus datasource proxy after a driven test
stream; an exemplar (`trace_id=fe003ccc0418d70b98728c8a9142919e`) attached to an
`inference_ttft_seconds_bucket` series resolved to a real trace in Tempo carrying the exact
expected span sequence (`recv → queue.wait → upstream.connect → ttft → stream.relay → settle`).
No relabel_configs were added in `compose/prometheus/prometheus.yml` beyond the static `app`/
`component` job labels — no forbidden-cardinality labels introduced (cardinality policy above).

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
