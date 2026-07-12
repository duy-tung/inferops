# Scenario 04 — Observation checklist

- [ ] `inference_requests_in_flight{backend="mock-faults"}` returns to (near-)0 after the run
      completes — no leaked in-flight slots from abandoned slow streams.
- [ ] Slow-population events (`workload_item`s flagged `slow_client` in `events.jsonl`) show
      `status` in {`canceled`,`ok`} with a bounded `e2e` duration close to the configured write
      deadline, never growing unbounded.
- [ ] Fast-population events show `ttft_seconds` consistent with baseline (~20ms mock TTFT +
      network), not inflated by the slow population sharing the gateway.
- [ ] No fast-population event shows an error attributable to the slow population (head-of-line
      blocking check).
- [ ] Verdict recorded; campaign-matrix row written; memory-growth clause recorded as an
      out-of-scope coverage gap (not measured), not silently assumed passing.
