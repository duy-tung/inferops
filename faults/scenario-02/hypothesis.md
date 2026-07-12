# Scenario 02 — Backend killed after first token

- **Contract reference:** `examples/faults/fs-02-backend-killed-after-first-token.json`
  (Contract 6, item 2).
- **Injection:** kill one engine backend process (SIGKILL, no drain) while it is mid-generation
  on streams that have already delivered >=1 token. Mechanism: dedicated `mock-faults`
  (`-ttft=100ms -itl=500ms`, so first chunk arrives fast and subsequent chunks are slow enough to
  guarantee several concurrent streams are genuinely mid-generation before the kill) behind
  `gateway-faults` (defaults). A background inferbench streaming population plus one directly
  captured `curl` stream are both running when `docker kill -s SIGKILL inferops-mock-faults`
  fires ~1.5s in (well past every stream's 100ms TTFT).
- **Expected gateway semantics (verbatim):**
  1. "Each affected stream receives the standardized mid-stream SSE error event
     (`error.type=upstream_error`) followed by stream close — never a retry."
  2. "Tokens already relayed before the failure are settled as partial usage under the stream's
     request ID (partial output is billable)."
- **Expected client-visible behavior:** "Mid-stream SSE error event carrying the request ID, then
  stream close; content received before the failure is retained; the platform never reconnects or
  re-generates on the client's behalf."
- **Metrics that must move:**
  - `inference_requests_total{status_class=5xx,error_class=upstream_error}` increases for the
    interrupted streams.
  - `inference_usage_tokens_total{direction=output}` increases by the partial token counts of the
    interrupted streams (settled, not discarded). Confirmed reachable under `-auth-mode=none`:
    `RequestTrace.Usage`/the Prometheus counter (`internal/telemetry/request.go:410-413`) is
    populated unconditionally in `recordUsage` — only the DB ledger write (`g.usage`) is
    auth-mode-gated, not this metric.
- **Metrics that must not move:** `inference_retries_total` does not increase for the interrupted
  streams — no retry after first token, ever. This is a structural code-path guarantee (the
  STREAMING-state failure handler, `gateway.go:749-761`, is entirely separate from the
  DISPATCHED-state pre-first-token retry loop and is explicitly never invoked once streaming has
  begun; infergate's own `internal/gateway/reliability_test.go` documents a "zero-post-first-token-
  retries proof"). This run does not disprove that guarantee — it observes it.
- **Abort condition (verbatim):** "Abort the injection if any interrupted stream is re-sent
  upstream (duplicate generation observed), or if settled usage for interrupted streams diverges
  more than 1% from client-observed token counts."
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-chat-short.json
  -stream -rate 4 -target http://127.0.0.1:8091 -model mock-8b` (seed 42042001) across the kill
  window, plus one directly captured raw SSE stream via `curl` for byte-level inspection.
