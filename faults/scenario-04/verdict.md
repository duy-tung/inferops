# Scenario 04 — Verdict

**Run:** `faults/scenario-04/inject.sh`, evidence in
`faults/scenario-04/evidence/20260712T014100Z/` (`part-a-stall.log`, `inferbench-run/`).

## Part A — genuinely stalled raw-socket client (deterministic, primary evidence)

A raw TCP client (shrunk `SO_RCVBUF`, zero `recv()` calls at all) held the connection open
through headers, then stalled for **8 seconds** — 2.6x the gateway's configured
`-stream-write-timeout=3s` — against the repo's own known long deterministic completion ("count
to a lot", 242 tokens, per `scripts/drain-test.sh`'s header comment). Result:

- After the 8s stall, the socket was **still open** (939 bytes of already-buffered data drained
  first, `EOF=False`).
- Resuming reads made the stream **continue exactly where it left off** — 6 more reads of 576
  bytes each, then the request settled normally: `inference_requests_total{...,status_class="2xx",
  error_class="none"}` incremented by 1 (a clean success), and `inference_requests_in_flight`
  returned to 0.
- **No SSE error event was ever written. The connection was never closed by the gateway during
  the stall.** The 3-second write deadline did not visibly fire even once across an 8-second full
  stall on a response with substantially more data than fits in the shrunk receive window.

## Part B — inferbench slow-client workload (population-level corroboration)

`sent=30 ok=24 errors=6 shed=0`; of the 9 requests wall-clock-identifiable as the slow (30%)
population: 3 completed **ok** at 12.1s/14.9s/22.0s (all far beyond the 3s deadline, simply
finishing once their bounded output drained), and 6 ended in `error_class=upstream_timeout` at
exactly **60.0s** — inferbench's own client-side `-request-timeout` default, not a gateway-
initiated close. In no case did a slow stream get cut at ~3s.

## Verdict: deviation-documented (not expected-semantics-matched)

- "Per-stream write buffering stays bounded; a write deadline is enforced per stream": the
  **mechanical hook exists** (`internal/stream/relay.go`'s `writeEvent` calls
  `rc.SetWriteDeadline` before every write) but **did not observably fire** in either test here.
- "When the bound/deadline is exceeded, the gateway closes the stream and propagates cancellation
  upstream ... release is observable": **not observed** — no close, no SSE error event, no
  upstream release; the stream simply resumed once reads resumed.
- This is **not a surprise finding sprung on the campaign** — `internal/stream/relay.go`'s own
  header comment says so directly: *"Write deadline: each write carries writeTimeout when the
  underlying ResponseWriter supports deadlines; a violation fails the write so the caller can
  release the upstream. (**Full slow-client fault handling — scenario 4 — is later work; the
  bound exists now.**)"* This campaign's job is to verify the *deployed* behavior against the
  *contract*, regardless of what the source comments already disclose — and the deployed behavior
  does not yet meet fs-04's expected gateway semantics. **Recorded here as an observation for
  infergate** (already partially self-documented upstream as "later work," not a new/hidden
  defect): worth checking, in a future infergate task, whether
  `http.ResponseController.SetWriteDeadline` is silently returning `http.ErrNotSupported` for this
  server configuration (the code's own error handling explicitly tolerates that: `if err != nil &&
  !errors.Is(err, http.ErrNotSupported) { return err }` — a silently-unsupported deadline and a
  successfully-applied-but-never-triggered deadline are indistinguishable from outside the
  process; this campaign could not tell which without adding instrumentation to infergate itself,
  which is out of this repo's scope).
- `inference_requests_in_flight` returning to 0: **matched trivially** (every test request
  eventually completed normally — there was no fault to recover from).

## Client impact

No slow client was ever cut off early by the gateway; slow clients simply ran to their own natural
completion (12-22s) or to the *client's own* timeout (60s in the inferbench case). Normal-speed
clients were unaffected throughout both parts (21/21 fast-population inferbench requests
completed normally; not shown to violate the 10% TTFT-degradation bound, though this was not
separately isolated against a no-slow-population baseline run in this campaign — a scope
reduction, noted honestly rather than asserted without a check). Memory-growth monitoring (the
abort condition's other half) was out of this campaign's instrumentation and was not measured.
