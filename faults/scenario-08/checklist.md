# Scenario 08 — Observation checklist

- [x] `scripts/config-rollout.sh` exists and is re-runnable (IO-T010).
- [x] Fresh re-run for this campaign completed: 0/23 short + 0/4 stream dropped.
- [x] `config_version` visibly advanced at both the rollout and the rollback
      (v3→v4→v5), each reported `trigger_to_publish` well under the 5s SLO.
- [x] New model alias observable in `/v1/models` after rollout; absent again after rollback.
- [ ] `inference_requests_in_flight` discontinuity check: not separately re-verified in this
      campaign run (already covered by the "0 dropped streams" measurement, which is the more
      direct client-visible proxy for the same property).
- [x] Verdict recorded, citing both the original IO-T010 evidence and this campaign's
      re-confirmation; campaign-matrix row written.
