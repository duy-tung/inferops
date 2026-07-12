# Scenario 06 — Queue saturation

- **Contract reference:** `examples/faults/fs-06-queue-saturation.json` (Contract 6, item 6):
  raise offered load above the admission bound so the queue reaches its configured cap.
- **Injection:** `gateway-faults` started with a deliberately tight admission configuration so
  saturation is reachable at modest load in a short test window:
  `-admission-tenant-queue-cap=4 -admission-global-inflight-budget=4
  -admission-global-queue-cap=8 -admission-queue-deadline=1s`, against `mock-faults -itl=300ms`
  (slow enough that in-flight slots stay occupied long enough for the queue to actually build).
  Load: `faults/workloads/fault-bursty.json` (2 rps base, then a 25 rps burst — well above the
  4-in-flight/8-queued budget) via inferbench.
- **Expected gateway semantics (verbatim):**
  1. "Excess requests are shed at admission with 429 + `Retry-After` and a typed error envelope
     (`error.type=rate_limited`) — shedding is explicit, never silent queue growth or connection
     resets." *(Note: per the transition table, admission-queue sheds under `-auth-mode=none`
     actually classify as `overloaded`/503 with reason `queue_full`/`global_overload` — the
     `rate_limited`/429 envelope is IG-T009's per-tenant quota gate, which requires DB-backed
     tenant auth and does not run under `-auth-mode=none`. This run checks the `overloaded`/503 +
     `Retry-After` form, which IS this deployment's admission-shed path; the discrepancy is
     recorded, not glossed over, in the verdict.)*
  2. "Accepted-request latency is protected: queue depth and queue wait stay at their configured
     bounds; requests already admitted keep meeting the latency SLO."
- **Expected client-visible behavior:** shed requests get a typed 429/503 + `Retry-After` +
  request ID; accepted requests are indistinguishable from no-fault operation.
- **Metrics that must move:** `inference_sheds_total{reason="queue_full"}` (and/or
  `global_overload`) increases while the overload lasts; `inference_queue_depth` plateaus at the
  configured bound; `inference_queue_wait_seconds` p95 for admitted requests stays bounded.
- **Metrics that must not move:** `inference_ttft_seconds` p95 of admitted requests stays within
  baseline SLO.
- **Abort condition (verbatim):** "Abort if accepted-request TTFT p95 exceeds the SLO threshold by
  more than 50%, or queue depth grows past its configured bound."
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-bursty.json
  -stream -target http://127.0.0.1:8091 -model mock-8b` (seed 42042006) across the burst window.
