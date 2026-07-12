# Scenario 07 — Observation checklist

- [ ] 10 aggressive no-backoff client workers run for a fixed window against gateway-faults +
      mock-faults (`-error-rate=0.3`).
- [ ] Total requests issued by the client fleet recorded (amplification denominator).
- [ ] `inference_retries_total{stage="pre_first_token"}` recorded; ratio to total dispatched
      requests computed and checked against the ~0.1 retry-budget-ratio, not just eyeballed.
- [ ] `inference_sheds_total` increases once the aggressive fleet's concurrency exceeds the
      admission budget.
- [ ] `inference_backend_healthy{backend="mock-faults"}` stays 1 throughout (error-rate-only
      injection, health probe unaffected).
- [ ] No stage other than `pre_first_token` ever appears in `inference_retries_total`.
- [ ] Verdict recorded, including the single-backend reduced-form note; campaign-matrix row
      written.
