# Scenario 05 — Gateway termination during streaming

- **Contract reference:** `examples/faults/fs-05-gateway-termination-during-streaming.json`
  (Contract 6, item 5): SIGTERM one gateway instance (normal orchestrated pod termination) while
  it is relaying active streams.
- **Already evidenced (IO-T004):** `scripts/drain-test.sh`
  (`scripts/evidence/drain-test-20260711T234926Z/`) already proved the core mechanism directly
  against the single main `gateway` container: SIGTERM sent 1.04s into a forced in-flight stream,
  the stream completed (200 + terminal `[DONE]`) despite the signal, a new request during the
  drain window got a typed 503, and the container exited on its own well inside the 50s grace
  budget. **This scenario's run re-confirms the same mechanism with a second, independent method
  (a 2-replica fleet + LB, matching fs-05's "new requests are served by the remaining instances"
  clause literally) and adds the inferbench client-impact measurement docs/testing.md requires for
  this scenario (1, 2, 5, 6, 12), which the IO-T004 curl-based test did not use.**
- **Injection:** `faults/lib.sh`'s `start_fleet` (mock-faults + `gateway-faults-a`/`-b` + a
  dedicated `haproxy-faults` LB, all no-auth so inferbench can drive them). A streaming inferbench
  population runs continuously against the LB; `docker kill -s SIGTERM inferops-gateway-faults-a`
  fires mid-run.
- **Expected gateway semantics (verbatim):**
  1. "On SIGTERM (via the preStop drain hook of the deployment contract) readiness goes false and
     no new requests are accepted [on that instance]."
  2. "Accepted streams run to completion within the termination grace period."
  3. "The process exits only after in-flight streams have completed."
- **Expected client-visible behavior:** "In-flight streams complete normally; new requests are
  served by the remaining instances; zero client-visible errors attributable to the termination."
- **Metrics that must move:** `inference_requests_in_flight` on the terminating instance drains to
  0 before exit; `inference_backend_healthy`/LB endpoint view of the terminating instance leaves
  rotation before its streams finish.
- **Metrics that must not move:** no `status_class=5xx` increase attributable to the termination
  window.
- **Abort condition (verbatim):** "Abort (and restore the instance) if any in-flight stream is
  dropped without a standardized SSE error event, or new requests are accepted after drain
  began."
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-chat-short.json
  -stream -target http://127.0.0.1:18091 -model mock-8b -rate 4` (seed 42042001) continuously
  across the SIGTERM+drain window.
