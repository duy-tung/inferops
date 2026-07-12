# Scenario 06 — Observation checklist

- [ ] gateway-faults up with the tightened admission config; mock-faults itl=300ms.
- [ ] During the burst phase, at least one request receives a 503/429 with a `Retry-After` header
      and a typed JSON error body carrying a request ID.
- [ ] `inference_sheds_total{reason="queue_full"}` and/or `{reason="global_overload"}` increases.
- [ ] `inference_queue_depth` sampled during the burst does not exceed the configured bound
      (global-queue-cap=8).
- [ ] Admitted (`ok`) requests' TTFT stays close to the mock's configured 20ms/itl-derived
      baseline — not inflated by the overload.
- [ ] `client_inference_ttft_seconds`-equivalent (inferbench's own `ttft_seconds` for `ok` events)
      p95 recorded as the accepted-request-latency-protected evidence.
- [ ] Verdict recorded, including the honest 429-vs-503 discrepancy note from hypothesis.md;
      campaign-matrix row written.
