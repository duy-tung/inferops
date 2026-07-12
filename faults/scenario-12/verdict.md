# Scenario 12 — Verdict

**Runs:** `faults/scenario-12/inject.sh`, evidence in
`faults/scenario-12/evidence/20260712T015749Z/` (`transcript.log`, `inferbench-run/`). **Also
citing:** `scripts/evidence/rolling-update-20260711T234628Z/` (IO-T004, curl-based proof — 0/27
short + 0/3 stream errors — re-confirmed here with inferbench).

## Observed

- `gateway-faults-a` drained (SIGTERM) and exited on its own in 1s; replacement started and
  became ready.
- `gateway-faults-b` drained and exited in 0s; replacement started and became ready.
- A streaming inferbench population (60 requests, rate 4, seed 42042001) ran continuously across
  the entire two-replica roll, routed through `haproxy-faults`.
- **`sent=60 ok=60 errors=0 shed=0` — zero client-visible errors across the full rollout.**

## Verdict: expected-semantics-matched

- "Each terminating instance follows fs-05 drain semantics": **matched** — both replicas drained
  and exited cleanly, never forcibly killed.
- "Each new instance follows fs-11 warm-up-aware readiness": **matched** — both replacements only
  entered LB rotation once their own `/readyz` returned 200 (haproxy's health check gate).
- "Aggregate ready capacity never falls below the disruption budget; zero client-visible errors":
  **matched** — at every instant at least one replica was serving, and the client-side record
  shows 0/60 errors.

No deviation to record. Combined with IO-T004's original curl-based proof (0/27 + 0/3), this
scenario now has two independent, zero-error confirmations using two different client
measurement tools.

## Client impact (streaming-critical scenario, inferbench)

60/60 requests succeeded across the complete rolling update of both replicas — the strongest
possible result for this scenario, consistent with hypothesis H1 ("rolling update under load with
correct probes/drain yields 0 client-visible errors").
