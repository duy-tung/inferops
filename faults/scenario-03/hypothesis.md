# Scenario 03 — Slow backend

- **Contract reference:** `examples/faults/fs-03-slow-backend.json` (Contract 6, item 3):
  degrade one backend's TTFT/ITL well above baseline (contract suggests `added_delay_ms=2000`,
  `scope=one-backend`) while it keeps accepting requests.
- **Injection:** mock-faults latency knobs stand in for network latency injection (the contract's
  own `injection.description` says the induced condition, not the tool, is normative — a
  gateway cannot distinguish "network added 2s" from "the engine itself took 2s"). Two parts:
  - **Part A (moderate slow, within budget):** `-ttft=1500ms` vs a `-ttft-timeout=4s` budget —
    every request completes, but slower than baseline; TTFT should be visibly elevated.
  - **Part B (severe slow, over budget):** `-ttft=3000ms` vs a tightened `-ttft-timeout=1500ms` —
    every request should exceed the phase deadline and fail typed `upstream_timeout`.
- **Expected gateway semantics (verbatim):**
  1. "Pressure-aware routing shifts new requests away from the slow backend within a bounded
     interval."
  2. "Requests that exceed upstream deadlines fail typed (`upstream_timeout`) — never as
     untyped/generic internal errors."
  3. "The slow backend is not marked dead while it still completes requests; it receives
     proportionally less traffic."
- **Expected client-visible behavior:** transient latency elevation, then recovery as routing
  shifts; deadline-exceeded requests surface a typed `upstream_timeout` envelope with the request
  ID.
- **Metrics that must move:** `inference_ttft_seconds` p99 rises for the injected backend;
  `inference_requests_total{error_class=upstream_timeout}` increases for deadline-exceeding
  requests; engine `queue_waiting_requests` (N/A — the mock engine exposes no Contract 4
  queue-depth signal; noted as a coverage gap, not faked).
- **Abort condition (verbatim):** "Abort if aggregate goodput across non-injected backends drops
  >20% below baseline for 120s, or untyped 5xx errors appear." (N/A: no non-injected backend
  exists in this reduced form.)
- **Known reduced form (recorded before running):** same single-backend CLI limitation as
  scenario 01 (`cmd/gateway/main.go:145-152`, IG-T012 not flag-driven for N>1) — clause 1
  ("routing shifts away... receives proportionally less traffic") is **not demonstrable**: there
  is no second backend to shift traffic to. This run demonstrates clauses 2 and 3 only, and
  clause 3's "not marked dead" half directly (health-probe independence from request latency,
  already established structurally in scenario 01/02: `/healthz` is a separate mock handler
  unaffected by `-ttft`/`-itl`).
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios (1,2,5,6,12);
  measured with direct `curl` timing instead, consistent with docs/testing.md's inferbench
  requirement covering only the streaming-critical five.
