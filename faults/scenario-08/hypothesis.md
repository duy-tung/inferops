# Scenario 08 — Config reload during traffic

- **Contract reference:** `examples/faults/fs-08-config-reload-during-traffic.json` (Contract 6,
  item 8): publish a gateway config change (routing weights, limits, tenant tiers) while streams
  are active and load is steady.
- **Already evidenced (IO-T010):** `scripts/config-rollout.sh` was built and run precisely for
  this mechanism (ADR-0002 snapshot swap), against `gateway-llamacpp` (the one instance in this
  repo running in reloadable-config mode). Original run:
  `scripts/evidence/config-rollout-20260712T002939Z/` — **0/24 short + 0/4 streaming requests
  dropped** across a rollout (new model alias added) and rollback, `config_version` v1→v2→v3.
- **This campaign's re-confirmation:** re-ran the identical, unmodified script fresh for the
  I7 record: `scripts/evidence/config-rollout-20260712T015039Z/` — **0/23 short + 0/4 streaming
  dropped**, `config_version` v3→v4→v5 (continuing the version sequence from the prior run,
  confirming the snapshot-swap mechanism is stable and repeatable, not a one-off).
- **Expected gateway semantics (verbatim):**
  1. "The new configuration applies as an atomic snapshot swap: in-flight requests complete under
     the snapshot they started with; new requests use the new snapshot."
  2. "Zero streams are dropped, reset, or errored by the reload."
  3. "The `inference.config_version` trace attribute changes at the swap, and the new config is
     effective within the config-publish SLO (<= 5s)."
- **Expected client-visible behavior:** "No client-visible interruption: active streams continue
  uninterrupted, no errors, no reconnects, no latency step attributable to the reload."
- **Metrics/observations that must move:** `inference_requests_total` continues increasing with
  `status_class=2xx` through the swap window; `config_version` visibly advances
  (v3→v4→v5, admin-endpoint-reported).
- **Metrics that must not move:** no `status_class=5xx` increase attributable to the reload;
  `inference_requests_in_flight` shows no discontinuity at the swap.
- **Abort condition (verbatim):** "Abort (and roll back) if any active stream terminates without
  normal completion during the swap window, or the new configuration is not effective within 5s
  of publish." Both reload and rollback here took well under 1ms (`trigger_to_publish` reported
  by the admin endpoint: 236.564µs and 141.223µs respectively) — many orders of magnitude inside
  the 5s SLO.
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios; the existing
  script's own curl-based short+stream client-side accounting (0 dropped in both runs) is the
  client-impact record, consistent with how this scenario was already evidenced at IO-T010.
