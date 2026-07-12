# Scenario 02 — Observation checklist

- [ ] mock-faults (ttft=100ms, itl=500ms) + gateway-faults up before injection.
- [ ] Background inferbench streaming population running; at least one directly captured raw
      `curl -N` SSE stream in flight.
- [ ] Kill issued only after every in-flight stream has passed its 100ms TTFT (checked via sleep
      >= 1s before the kill).
- [ ] Captured raw stream's SSE body ends with a standardized error event (`data: {"error":
      {...}}`) and no further `data:` lines after it (connection genuinely closed, not hung).
- [ ] `inference_requests_total{...,status_class="5xx",error_class="upstream_error"}` increases by
      roughly the number of streams that were mid-generation at kill time.
- [ ] `inference_usage_tokens_total{direction="output",...}` increases (partial tokens settled,
      not discarded/zeroed).
- [ ] `inference_retries_total` shows no increase attributable to the interrupted streams
      specifically (cross-checked against scenario 1's already-established pre-dispatch-only
      retry behavior).
- [ ] inferbench `events.jsonl`: every `status=error` event that also has a non-null
      `ttft_seconds` (i.e. it had already started receiving) shows `error_class=upstream_error`
      and a nonzero `output_tokens` count consistent with partial delivery — never a duplicate
      request ID, never truncated-then-resumed content.
- [ ] Verdict recorded; campaign-matrix row written.
