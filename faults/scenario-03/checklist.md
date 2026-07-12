# Scenario 03 — Observation checklist

- [ ] Part A (moderate slow, within budget): N requests complete successfully; measured TTFT is
      visibly elevated vs. the baseline (mock default `ttft=20ms`).
- [ ] `inference_backend_healthy{backend="mock-faults"}` stays 1 throughout Part A and Part B
      (slow is not the same as dead).
- [ ] Part B (severe slow, over budget): requests fail with a typed `upstream_timeout` envelope
      (never a bare/untyped 5xx, never a hang past the configured deadline).
- [ ] `inference_requests_total{...,error_class="upstream_timeout"}` increases in Part B.
- [ ] Deviation recorded: no second backend exists, so "routing shifts away" cannot be observed —
      confirmed absent from this run's evidence rather than asserted without a check.
- [ ] Verdict recorded; campaign-matrix row written.
