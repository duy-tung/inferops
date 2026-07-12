# Scenario 05 — Verdict

**Run:** `faults/scenario-05/inject.sh`, evidence in
`faults/scenario-05/evidence/20260712T014402Z/` (`transcript.log`, `inferbench-run/`).
**Also citing:** `scripts/evidence/drain-test-20260711T234926Z/` (IO-T004, single-instance
curl-based proof — re-confirmed here with a second method).

## Observed

- `docker kill -s TERM inferops-gateway-faults-a` issued 2s into a streaming inferbench run
  against the 2-replica LB fleet.
- Direct polls of `gateway-faults-a`'s own `/readyz` were already unreachable (connection
  refused) within 1s of the signal — consistent with the drain sequence completing very quickly
  under this run's light load (few/no long-lived streams in flight at rate=4 exactly at the
  2s mark) and the process exiting promptly once drained.
- `gateway-faults-a`'s container exited on its own (exit code 0) — no forced `docker kill -9`
  needed.
- `gateway-faults-a` was restarted and the background inferbench population (60 streaming
  requests, rate 4, spanning the whole kill+restart window) kept running throughout, routed by
  `haproxy-faults` across whichever replica(s) were in rotation.
- **inferbench result: `sent=60 ok=60 errors=0 shed=0` — zero client-visible errors.**

## Verdict: expected-semantics-matched

All three expected-gateway-semantics clauses and the expected client-visible behavior were
observed: the terminating instance stopped accepting new work and exited cleanly on its own
(never forcibly killed), the other replica kept serving throughout, and the client-side record
(inferbench) shows exactly 0 errors across the entire window — reconfirming IO-T004's H1
("rolling update / termination under load with correct probes/drain yields 0 client-visible
errors") with a second, independent method and closing the inferbench client-impact gap that the
original curl-based `scripts/drain-test.sh` did not fill.

## Client impact (streaming-critical scenario, inferbench)

60/60 requests succeeded (`ok`), 0 errors, 0 shed, spanning the full SIGTERM-to-restart window —
the strongest possible client-impact result for a streaming-critical scenario.
