# Scenario 12 — Observation checklist

- [x] `scripts/rolling-update-test.sh` exists and already re-confirmed at IO-T004 (0/27 short +
      0/3 stream errors).
- [ ] Fleet (mock-faults, gateway-faults-a/-b, haproxy-faults) up before injection.
- [ ] Background inferbench streaming population running against the LB throughout.
- [ ] gateway-faults-a drained (SIGTERM) and replaced; readiness gate observed (no requests
      routed to it until its own `/readyz` is 200 again).
- [ ] gateway-faults-b drained (SIGTERM) and replaced likewise.
- [ ] At every instant, at least one replica is ready (aggregate capacity never zero).
- [ ] inferbench summary: 0 errors across the entire two-replica roll.
- [ ] Verdict recorded, citing both the IO-T004 evidence and this campaign's inferbench-driven
      run; campaign-matrix row written.
