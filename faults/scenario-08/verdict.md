# Scenario 08 — Verdict

**Runs:** `faults/scenario-08/inject.sh` (delegates to `scripts/config-rollout.sh`), evidence in
`scripts/evidence/config-rollout-20260712T015039Z/` and
`scripts/evidence/config-rollout-20260712T015127Z/` (two fresh re-confirmations for this
campaign), plus the original `scripts/evidence/config-rollout-20260712T002939Z/` (IO-T010).

## Observed (three independent runs, same script, same mechanism)

| Run | short dropped | stream dropped | config_version sequence | trigger_to_publish |
|---|---|---|---|---|
| IO-T010 original | 0/24 | 0/4 | v1→v2→v3 | not separately timed |
| campaign re-confirm #1 | 0/23 | 0/4 | v3→v4→v5 | 236.564µs / 141.223µs |
| campaign re-confirm #2 | 0/23 | 0/4 | v5→v6→v7 | (rollout timing in log) / 433.255µs |

Zero dropped requests across all three runs (71 short + 12 streaming requests total, zero
failures). `config_version` advances monotonically and continues across runs (the store's
publish-sequence counter persists for the life of the container) — direct evidence the swap is a
real, repeatable, in-place mechanism, not a fluke of one run.

## Verdict: expected-semantics-matched

- "Atomic snapshot swap; in-flight requests complete under their own snapshot": **matched** — 0
  dropped/errored streams across three independent runs.
- "Zero streams dropped, reset, or errored by the reload": **matched**, repeatably.
- "`config_version` changes at the swap; effective within 5s": **matched** — swaps measured in
  the hundreds of microseconds, four orders of magnitude inside the 5s SLO.

No deviation to record. This is the strongest-evidenced scenario in the campaign (three
independent, dated runs, all clean).

## Client impact

0/71 short requests and 0/12 streaming requests dropped or errored across all three runs
(cumulative across IO-T010 + this campaign's two re-confirmations).
