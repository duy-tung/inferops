# Scenario 07 — Verdict

**Run:** `faults/scenario-07/inject.sh`, evidence in
`faults/scenario-07/evidence/20260712T014939Z/` (`gateway-metrics-{after,part2}.txt`, per-worker
count CSVs).

**Methodology correction found and fixed before the results below:** the mock engine's error
injection is a **deterministic hash of the request body** ("same config + same request always
yields the same value," `internal/mockengine/engine.go:124`) — sending the identical fixture
repeatedly (the first attempt at this script) always landed the same pass/fail outcome for that
one fixture (1261/1261 succeeded, `-error-rate=0.3` notwithstanding), not a real 30% sample. Fixed
by varying the prompt text per request (worker id + counter) so each distinct request samples the
configured rate independently, as real varied client traffic would. Recorded here rather than
silently corrected, since a naive read of the first attempt's numbers would have been wrong.

## Part 1 — moderate admission (10 in-flight / 10 queue), aggressive fleet, error-rate 0.3

10 workers, 15s, zero backoff: **1740 requests issued**, 1219 ok, 521 typed `upstream_error`.
`inference_retries_total{stage="pre_first_token"}=174`.

**174 / 1740 = 0.100 — an exact match to the configured `retry-budget-ratio=0.1`.** This is a
clean, direct confirmation that the gateway's retry-triggered upstream load stays capped at
precisely its configured fraction of total request volume, regardless of the client fleet hammer
rate or the 0.3 engine error rate (which alone, with naive one-retry-per-failure behavior, would
have implied ~0.3, not 0.1).

## Part 2 — tight admission (3 in-flight / 3 queue), same fleet

**5032 requests issued** (fleet completed faster per request once most were shed, hence the much
higher count in the same 15s): 397 ok, 185 `upstream_error`, **4450 typed 503
`overloaded`/`queue_full`** — i.e. **88% of the storm's offered load was shed at admission**, not
forwarded upstream. `inference_retries_total=57` against 582 actually-dispatched (ok+upstream_error)
requests = 0.098, again matching the 0.1 budget ratio on the population that WAS dispatched.

## Verdict: expected-semantics-matched, with one documented, structural deviation

- "The gateway's retry budget caps amplification ... regardless of client behavior": **matched**,
  precisely (0.100 and 0.098 measured vs. 0.10 configured, across two very different admission
  configurations and fleet outcomes).
- "Excess offered load from client retries is handled by admission control ... not forwarded
  upstream": **matched** — Part 2's 88% shed rate under a tight budget.
- "All gateway retries remain pre-first-token only": **matched** — no other stage value ever
  appeared in `inference_retries_total`.
- "`inference_backend_healthy` stays 1 for non-injected backends": **not demonstrable** — same
  single-backend reduced-form limitation as scenarios 01/03/10
  (`cmd/gateway/main.go:145-152`). `inference_backend_healthy{backend="mock-faults"}` (the one
  backend that exists) stayed 1 throughout both parts, confirming health-probe independence from
  the error-rate-driven request failures (consistent with scenario 01/03's findings). **Deviation,
  documented, not a defect.**

## Client impact

Not one of the five inferbench-mandated scenarios; measured with the aggressive client fleet's own
accounting (the literal mechanism the contract names). No untyped errors in either part; every
non-2xx outcome was a typed `upstream_error` or typed 503 `overloaded` + implicit shed semantics
consistent with scenario 06.
