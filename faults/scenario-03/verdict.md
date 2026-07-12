# Scenario 03 — Verdict

**Run:** `faults/scenario-03/inject.sh`, evidence in
`faults/scenario-03/evidence/20260712T013136Z/` (part-{a,b}-timings.csv, part-{a,b}-metrics.txt).

## Part A — moderate slow, within budget (ttft=1.5s, ttft-timeout=4s)

8/8 requests succeeded (HTTP 200), each taking ~1.73s wall time (elevated vs. the ~20ms baseline
by design) — visible, bounded latency elevation, no failures.
`inference_backend_healthy{backend="mock-faults"}` stayed **1**.

## Part B — severe slow, over budget (ttft=3s, ttft-timeout=1.5s)

8/8 requests failed with **HTTP 504**, body:
`{"error":{"message":"Upstream backend did not respond within the deadline.",
"type":"upstream_timeout","code":null,"param":null,"request_id":"req_..."}}` — a **typed**
envelope every time, never a bare/untyped 5xx, always carrying the request ID, at a consistent
~1.51s wall time (matching the 1.5s `ttft-timeout`, confirming the phase deadline — not the total
ceiling — is what fired). `inference_backend_healthy{backend="mock-faults"}` **stayed 1** even
though every single request in this window timed out — the health probe (`/healthz`, unaffected
by `-ttft`) correctly kept reporting reachability separately from request-level slowness.
`inference_sheds_total` stayed at 0 across the board (these are typed FAILED outcomes, not
shed/admission outcomes — correct per the fault-state-machine's DISPATCHED→FAILED(upstream_timeout)
edge, not a SHED edge).

## Verdict: expected-semantics-matched, with one documented, structural deviation

- "Requests that exceed upstream deadlines fail typed (`upstream_timeout`) — never untyped":
  **matched**, byte-for-byte.
- "The slow backend is not marked dead while it still completes requests" (health independence
  half): **matched** — even at 100% timeout rate, health stayed 1.
- "Pressure-aware routing shifts new requests away from the slow backend ... receives
  proportionally less traffic": **not demonstrable** — this release's gateway CLI wires exactly
  one backend into `route.Router` (`cmd/gateway/main.go:145-152`, IG-T012 "not yet flag-driven for
  N>1", infergate's own recorded scope reduction). **Deviation, documented, not a defect** — same
  root cause as scenario 01's reduced form. A conclusive test of this clause requires infergate to
  expose N-backend configuration on the released binary.
- `engine queue_waiting_requests` (Contract 4 canonical signal): **not observed** — the mock
  engine's `/metrics` exposes no queue-depth signal to map via a capability descriptor (checked:
  `internal/mockengine` has no such gauge). Recorded as a coverage gap specific to the mock
  backend, not a gateway defect; the llama.cpp path (IO-T005) would be the place to close it in a
  future run, out of scope here.

## Client impact

Not one of the five inferbench-mandated scenarios (docs/testing.md: 1, 2, 5, 6, 12); measured
directly instead — Part A shows a bounded, predictable ~1.73s per-request latency elevation (no
failures); Part B shows a clean, deadline-bounded typed failure (~1.51s to a definitive 504,
never a hang).
