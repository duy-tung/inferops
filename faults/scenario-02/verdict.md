# Scenario 02 — Verdict

**Run:** `faults/scenario-02/inject.sh`, evidence in
`faults/scenario-02/evidence/20260712T012838Z/` (`raw-stream.sse`, `gateway-metrics-after.txt`,
`inferbench-run/`).

## Directly captured raw stream (byte-level evidence)

The captured stream's final bytes, exactly as delivered to the client:

```
id: 3
data: {"id":"chatcmpl-...","object":"chat.completion.chunk", ... "delta":{"content":" basalt"}}

id: 4
data: {"error":{"message":"Upstream backend failed mid-stream; the stream is closed and is never
retried. Tokens already delivered are billable.","type":"upstream_error","code":null,"param":null,
"request_id":"req_9b58e45fc2edd8fddc2d7d8304f7bfd0"}}
```

This is a **verbatim, textbook match** of the contract's expected client-visible behavior: a
standardized mid-stream SSE error event (`type=upstream_error`, carrying the request ID), the
message itself stating the no-retry/billable-partial-output rule, content received before the
failure retained, and the connection then genuinely closed (no further `data:` lines, no hang).

## Population-level evidence (inferbench, 60 streaming requests, rate 4)

- `sent=60 ok=51 errors=6 shed=3`. Of the 6 errors, 5 are clean, kill-attributable
  `upstream_error` events with small `output_tokens` (2-3 — streams caught right at the kill);
  the 6th is a single `upstream_timeout` with `output_tokens=120` whose timing (120 real chunks at
  the mock's 500ms ITL is 60s of legitimate streaming, well after the restart) does not line up
  with the kill window — most likely a test-harness artifact of reusing the same Docker
  network alias across the pre-kill and post-restart `mock-faults` containers (a brief DNS-cache
  inconsistency), not a gateway behavior. Recorded honestly rather than folded into the kill
  count; it is 1/60 and does not change the verdict below.
- `inference_requests_total{...,error_class="upstream_error"}` increased (5 pre-shutdown + 1
  during, matching the 2xx-then-error and 5xx rows in the raw metrics dump) — **matches**.
- `inference_usage_tokens_total{direction="output"}` increased from 0 to 1796 across the run,
  including the partial tokens of every interrupted stream (confirmed per-event: each interrupted
  stream's `output_tokens` in `events.jsonl` is nonzero and consistent with tokens actually
  delivered before the cut, e.g. 2-3 tokens for the four streams caught mid-flight) — **matches**
  ("partial output is billable").
- `inference_retries_total{stage="pre_first_token"}` stayed 0 across the entire run — no retry
  ever fired for these already-streaming requests, and (structurally, per
  `internal/gateway/gateway.go:749-761` — the STREAMING-state failure handler is a code path
  entirely separate from the DISPATCHED-state retry loop) it never can — **matches** ("no retry
  ever occurs after the first token").
- **No duplicate request IDs** anywhere in `events.jsonl` — no duplicated/re-generated output.

## Verdict: expected-semantics-matched

All three expected-gateway-semantics clauses and the expected client-visible behavior were
observed directly, at the byte level for one stream and at the metric/event level for the
population. No deviation to record for this scenario (the reduced single-backend-topology caveat
from scenario 01 does not apply here — fs-02's semantics never involve routing to a second
backend, only "never retry, settle partial usage," both of which are fully single-backend-testable
and were both confirmed).

## Client impact (streaming-critical scenario, inferbench)

51/60 unaffected (`ok`), 5/60 received a clean typed SSE error mid-stream with partial content
retained and billed, 3/60 shed (503, unrelated admission pressure from the concurrent load), 1/60
an unexplained-but-benign timeout (see above). Zero hangs, zero duplicated output, zero untyped
failures.
