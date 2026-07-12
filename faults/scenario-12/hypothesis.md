# Scenario 12 — Rolling update with active requests

- **Contract reference:** `examples/faults/fs-12-rolling-update-with-active-requests.json`
  (Contract 6, item 12): rolling update of the serving deployment while streams are active and
  load is steady. Composition of scenario 5 (drain) + scenario 11 (warm-up-aware readiness) at
  the fleet level, per infergate's own fault-state-machine doc §4.
- **Already evidenced (IO-T004):** `scripts/rolling-update-test.sh` — 2-replica `gateway-a`/
  `gateway-b` + haproxy, scripted live load (steady short requests + periodic long SSE streams),
  one replica drained-and-replaced at a time. Original run:
  `scripts/evidence/rolling-update-20260711T234628Z/` — **0/27 short + 0/3 long-stream
  client-visible errors** across both replicas' rolls.
- **This campaign's addition:** docs/testing.md requires inferbench specifically for this
  scenario's client-impact measurement (the IO-T004 script used curl-based accounting, not
  inferbench). Mechanism: `faults/lib.sh`'s `start_fleet` (no-auth `gateway-faults-a`/`-b` +
  `haproxy-faults`, so inferbench — which sends no Authorization header — can drive it), a
  continuous streaming inferbench population, and a full sequential roll: drain+replace
  `gateway-faults-a`, then drain+replace `gateway-faults-b`.
- **Expected gateway semantics (verbatim):**
  1. "Each terminating instance follows fs-05 drain semantics: preStop drain, readiness false,
     accepted streams complete within the grace period."
  2. "Each new instance follows fs-11 warm-up-aware readiness: no traffic before warm, no restart
     loops."
  3. "Aggregate ready capacity never falls below the disruption budget; the rollout completes with
     zero client-visible errors."
- **Expected client-visible behavior:** "Zero client-visible errors across the entire rollout:
  in-flight streams complete, new requests land only on ready instances, latency stays within
  SLO."
- **Metrics that must move:** `inference_requests_in_flight` drains to 0 per terminating instance
  in sequence, aggregate never drops to 0; `inference_backend_healthy`/LB endpoint view
  transitions 1→0 (drain) and 0→1 (warm) per instance, never all at once.
- **Metrics that must not move:** no `status_class=5xx` increase attributable to the rollout;
  client-side TTFT p95 stays within SLO throughout.
- **Abort condition (verbatim):** "Abort (pause the rollout, keep current instances) if any
  client-visible error is attributable to the rollout, or ready capacity falls below the
  disruption-budget floor."
- **Client-impact measurement:** `inferbench run -workload faults/workloads/fault-chat-short.json
  -stream -target http://127.0.0.1:18091 -model mock-8b -rate 4` (seed 42042001) continuously
  across the entire two-replica roll.
