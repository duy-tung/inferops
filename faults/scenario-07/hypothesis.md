# Scenario 07 — Retry storm

- **Contract reference:** `examples/faults/fs-07-retry-storm.json` (Contract 6, item 7): induce
  failures on one backend while a client fleet retries aggressively (immediate, no backoff/jitter)
  trying to amplify load through the gateway.
- **Injection:** `mock-faults -error-rate=0.3` (induced backend failures) behind `gateway-faults`
  with a moderately tightened admission budget (`-admission-tenant-queue-cap=10
  -admission-global-inflight-budget=10`, default retry budget: `retry-budget-ratio=0.1
  retry-max-attempts=2`) and a real aggressive client fleet: **10 concurrent bash workers**, each
  looping `curl` with **zero backoff/sleep between an error and the next attempt** for a fixed
  15s window — the literal client behavior the contract names, not a stand-in.
- **Expected gateway semantics (verbatim):**
  1. "The gateway's retry budget caps amplification: gateway-initiated upstream retries never
     exceed the configured budget fraction of base request rate, regardless of client behavior."
  2. "Excess offered load from client retries is handled by admission control (fs-06 semantics:
     429/503 + `Retry-After`), not forwarded upstream."
  3. "All gateway retries remain pre-first-token only."
- **Expected client-visible behavior:** storming clients increasingly receive 429/503 +
  `Retry-After` once budgets engage; well-behaved clients continue to meet the latency SLO (N/A
  here — no separate well-behaved population is run alongside the storm in this reduced test;
  recorded as a scope reduction).
- **Metrics that must move:** `inference_retries_total` increases, but bounded near the
  `retry-budget-ratio` (0.1) fraction of total dispatched requests — checked directly against the
  raw counters, not assumed; `inference_sheds_total` increases once budgets/admission engage.
- **Metrics that must not move:** `inference_backend_healthy` stays 1 for non-injected backends —
  **not demonstrable**: single-backend reduced form (same `cmd/gateway/main.go:145-152` limitation
  as scenarios 01/03/10). `inference_backend_healthy{backend="mock-faults"}` itself is checked
  instead (should stay 1 throughout, since `-error-rate` never touches `/healthz`, established in
  scenario 01).
- **Abort condition (verbatim):** "Abort if upstream request rate exceeds (1 + retry-budget
  fraction) x offered base rate, or a non-injected backend saturates." (N/A: no non-injected
  backend in this reduced form; the gateway-side check below is the retries_total/dispatched
  ratio instead.)
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios; measured with
  the aggressive bash client fleet's own request/response accounting (the closest fit to "an
  aggressive, non-backoff retrying client fleet," which inferbench's schema-driven seeded workload
  model does not represent — inferbench workloads describe *offered* traffic shape, not
  *reactive* client-retry behavior).
