# Scenario 10 — One unhealthy backend

- **Contract reference:** `examples/faults/fs-10-one-unhealthy-backend.json` (Contract 6, item
  10): make one backend of a multi-backend pool persistently unhealthy (fails fast) while others
  stay healthy.
- **Injection:** `docker pause inferops-mock-faults` (SIGSTOP-equivalent — freezes the ENTIRE
  process, including its `/healthz` handler, unlike the `-error-rate` flag used in scenarios
  01/03/07 which deliberately leaves `/healthz` answering; this is the mechanism that actually
  makes the health poller itself detect unhealthiness, not just request-level errors) against
  `gateway-faults` (default health-poll interval 200ms / probe timeout 150ms) while a steady
  traffic stream runs, then `docker unpause` to restore.
- **Expected gateway semantics (verbatim):**
  1. "Routing shifts away from the unhealthy backend within a bounded interval; its circuit opens
     on error rate and only probe traffic reaches it while open."
  2. "Errors surfaced to clients before the shift are typed (`upstream_error`) and pre-first-token
     failures are retried within budget against healthy backends (fs-01 semantics)."
  3. "The circuit re-closes only after successful probes when the backend recovers."
- **Expected client-visible behavior:** "At most a brief, bounded window of elevated typed errors
  and retry-elevated TTFT, then recovery to baseline while the backend stays down."
- **Metrics that must move:** `inference_backend_healthy` goes to 0 within the bounded detection
  interval (poll 200ms + probe timeout 150ms ≈ well under 1s); the backend's share of requests
  drops to ~probe-only once unhealthy; `inference_retries_total{stage=pre_first_token}` increases
  during the shift/stale window (the IG-T017 staleness-window mechanism this repo's fault-state-
  machine doc cites).
- **Abort condition (verbatim):** "Abort if the routing shift takes longer than twice the
  configured detection bound, or requests keep routing to the backend while its circuit is open."
- **Known reduced form (recorded before running):** same single-backend CLI limitation as
  scenarios 01/03/07 (`cmd/gateway/main.go:145-152`) — "routing shifts away... to healthy
  backends" cannot be demonstrated in its literal multi-backend form. This run demonstrates the
  health-detection, retry-during-staleness, and recovery clauses, which are all single-backend-
  testable (the staleness window exists regardless of pool size — it is purely a function of the
  poll interval vs. request-failure-detection latency).
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios; measured with
  a direct curl request loop (finer time resolution around the exact pause/unpause instants than
  a seeded inferbench workload would give).
