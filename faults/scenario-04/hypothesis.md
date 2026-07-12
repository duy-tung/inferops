# Scenario 04 — Slow client

- **Contract reference:** `examples/faults/fs-04-slow-client.json` (Contract 6, item 4): a
  fraction of streaming clients read the SSE response far slower than tokens are produced.
- **Injection:** inferbench's `slow_client` workload feature (`internal/client` throttles the
  reader to `read_bytes_per_second` with an optional initial delay) — the client-side mechanism
  the contract itself names (`workload.slow_client`), run against `gateway-faults` (a dedicated
  no-auth instance with a deliberately tightened `-stream-write-timeout=3s`, vs. the released
  default of 30s, so the write-deadline closure is observable inside a short test window rather
  than waiting a full half-minute per slow stream) + `mock-faults` (baseline `-ttft=20ms
  -itl=8ms`). Workload: `faults/workloads/fault-slow-client.json` — 30% of requests throttled to
  128 B/s with a 0.2s initial read delay, 70% read at full speed.
- **Expected gateway semantics (verbatim):**
  1. "Per-stream write buffering stays bounded; a write deadline is enforced per stream."
  2. "When the bound/deadline is exceeded, the gateway closes the stream and propagates
     cancellation upstream (HTTP body close) so the engine aborts generation and releases the
     request's resources — release is observable."
  3. "Slow consumers never cause head-of-line blocking or memory growth affecting other streams."
- **Expected client-visible behavior:** slow clients see their stream closed after the write
  deadline (tokens delivered before the close retained/billable); normal-speed clients are
  unaffected (TTFT/ITL stay at baseline).
- **Metrics that must move:** `inference_requests_in_flight` returns to baseline after the
  write-deadline closes (engine-side release confirmed, not assumed); `inference_e2e_duration_seconds`
  for slow streams terminates at the write deadline instead of growing unbounded.
- **Metrics that must not move:** `client_inference_ttft_seconds` p95 for the normal-speed
  population stays within 10% of baseline.
- **Abort condition (verbatim):** "Abort if gateway memory grows monotonically with slow-client
  count, or normal-speed clients' TTFT p95 degrades more than 10% from baseline." (Memory growth
  is out of this campaign's instrumentation scope — not measured; recorded as a coverage gap.)
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-slow-client.json
  -stream -target http://127.0.0.1:8091 -model mock-8b` (seed 42042004) — this IS one of
  inferbench's own client-side-observable mechanisms (slow-client read throttling), so the
  population itself is the client-impact measurement; scenario 4 is not in the
  inferbench-mandated five (1,2,5,6,12) but the same tool is the natural fit here regardless.
- **Pre-run source note (read before finalizing this hypothesis, kept for the record):**
  `internal/stream/relay.go`'s own header comment states the bound is partial: "Write deadline:
  each write carries writeTimeout when the underlying ResponseWriter supports deadlines; a
  violation fails the write so the caller can release the upstream. (**Full slow-client fault
  handling — scenario 4 — is later work; the bound exists now.**)" This hypothesis is written
  expecting the mechanical per-write deadline to fire under a genuinely stalled reader, per that
  comment — but flags upfront that infergate's own source does not promise the full contract
  behavior yet, so a negative result here would corroborate a known, already-declared gap rather
  than surface a surprise.
