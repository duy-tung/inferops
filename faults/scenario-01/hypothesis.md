# Scenario 01 — Backend killed before first token

- **Contract reference:** `serving-contracts/schemas/fault-scenario.schema.json`, fixture
  `examples/faults/fs-01-backend-killed-before-first-token.json` (Contract 6, item 1).
- **Injection:** kill one engine backend process (SIGKILL, no drain) while it holds admitted
  requests that have not yet produced a first token. Mechanism used here: a dedicated,
  released-digest `mock-backend` instance (`inferops-mock-faults`) started with `-ttft=3s` (a wide
  pre-first-token window) behind a dedicated no-auth `gateway-faults` instance
  (`inferops-gateway-faults`, released `infergate` digest, default retry/breaker config:
  `retry-budget-ratio=0.1`, `retry-max-attempts=2`, `breaker-window=10s`,
  `breaker-failure-threshold=0.5`). `docker kill -s SIGKILL inferops-mock-faults` is sent ~1.5s
  into a streaming inferbench run, while every in-flight request is still inside its 3s TTFT
  window (pre-first-token by construction). The backend is restarted a few seconds later so the
  same run also observes recovery.
- **Expected gateway semantics (verbatim from fs-01):**
  1. "Requests on the killed backend that have not received a first upstream body byte are
     retried pre-first-token against another healthy backend, within the retry budget."
  2. "If the retry budget is exhausted or no healthy backend exists, the request fails with a
     typed error envelope (`error.type=upstream_error`, 5xx) carrying the request ID."
  3. "No retry ever occurs after the first token."
- **Expected client-visible behavior:** "Either a successful response/stream (transparent
  pre-first-token retry; TTFT elevated) or a typed `upstream_error` envelope — never partial
  output, never duplicated output."
- **Metrics that must move:**
  - `gateway inference_retries_total` — increases with `stage=pre_first_token` for retried
    requests.
  - `gateway inference_backend_healthy` — goes to 0 for the killed backend within the
    health-check interval (Router poll interval default 200ms).
  - `gateway inference_requests_total` — `error_class=upstream_error` increases only for requests
    that exhausted the retry budget.
- **Metrics that must not move:** `inference_retries_total` never carries a stage other than
  `pre_first_token`.
- **Abort condition (verbatim):** "Abort the injection if any client observes duplicated output
  tokens, or if the error rate of requests routed to non-injected backends exceeds 5% for 60s."
  (N/A here — single-backend deployment, no non-injected backend exists; abort instead if any
  client response body is truncated/duplicated relative to its own request.)
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-chat-short.json
  -stream -rate 4 -target http://127.0.0.1:8091 -model mock-8b`, run continuously across the
  kill+restart window (seed 42042001, `stop.request_count=60`).
- **Known reduced form (recorded before running, not discovered after):** this release's gateway
  binary wires exactly one backend into `internal/route.Router` from CLI flags — N-backend
  routing (`internal/route` / IG-T012 selection logic) exists in the code but is "not yet
  flag-driven for N>1" (infergate's own recorded scope reduction, `cmd/gateway/main.go:145-152`).
  With a single backend, clause 1 ("retried against ANOTHER healthy backend") cannot be
  demonstrated in its full multi-backend form; this run demonstrates clause 2/3 fully (retry is
  attempted and counted, then fails typed while the backend is down) and demonstrates recovery
  (once the backend restarts and health flips back to 1, subsequent requests succeed normally —
  the closest same-hardware analogue of "a healthy backend" reachable without standing up a second
  full backend). This is a documented deviation, not a defect: infergate's own source records the
  scope reduction.
