# Scenario 06 — Verdict

**Run:** `faults/scenario-06/inject.sh`, evidence in
`faults/scenario-06/evidence/20260712T014522Z/` (`burst-headers.txt`, `gateway-metrics-final.txt`,
`inferbench-run/`).

## Observed

- A manual 20-way concurrent burst against the tightened gateway (`-admission-tenant-queue-cap=4
  -admission-global-inflight-budget=4 -admission-global-queue-cap=8
  -admission-queue-deadline=1s`) produced clean, **typed 503 responses with `Retry-After: 1` and
  a request ID** for every shed request:
  ```
  HTTP/1.1 503 Service Unavailable
  Content-Type: application/json
  Retry-After: 1
  X-Request-Id: req_a7e2ff61eba45f72bab8fe3fae64a8fa
  ```
  `inference_sheds_total{reason="queue_full"}` incremented by 16 for that burst alone.
- inferbench `fault-bursty.json` (2 rps base → 25 rps burst, 20s window): `sent=399 ok=3 errors=4
  shed=392`. The shed rate is very high relative to a "some shed, some admitted" expectation —
  the 4-in-flight/8-queue budget is small enough relative to a 25 rps burst that admission almost
  always finds the queue already full; this is the deliberately tightened config doing exactly
  its job (protecting a very small admitted population) rather than a partial-shedding profile.
- Admitted (`ok`) population: **n=3, ttft p50=p95=24ms** — right at the mock's 20ms baseline (+
  network/relay overhead), i.e. admitted requests were not slowed down by the overload. The small
  n (3) limits how strong a statistical claim this is; recorded honestly rather than inflated.
- 4 requests failed `upstream_timeout` rather than `ok` or `shed` — these were **admitted**
  (passed the queue) but the workload's output cap (512 tokens) at `-itl=300ms` implies up to
  ~154s of legitimate streaming time against this gateway's **default** `-upstream-timeout=30s`
  (not overridden for this scenario) — an unrelated confound from the itl/workload-cap
  combination, the same class of issue found and fixed in scenario 02's first run. Recorded here
  rather than re-run, since it does not change the scenario's core finding (admission correctly
  protects the tiny admitted population; these 4 are a workload-tuning artifact, not an admission
  failure).
- `inference_queue_depth` was only sampled **after** each burst settled (0 both times) — this
  campaign did not capture a mid-burst sample of the gauge, so "queue depth plateaus at the
  configured bound" is not independently confirmed by a time series here, only inferred from the
  shed counts. Recorded as a measurement-timing gap, not asserted as directly observed.

## Verdict: expected-semantics-matched, with one documented, expected discrepancy

- "Excess requests are shed at admission with 429/503 + `Retry-After` and a typed envelope":
  **matched** in substance (503 `overloaded`, typed, `Retry-After` present, request ID present).
  The contract fixture's literal wording is `error.type=rate_limited`/429 — under `-auth-mode=none`
  (required so inferbench can drive load; see faults/lib.sh's header note) there is no tenant
  identity for IG-T009's quota gate to key on, so *this* deployment's admission-shed path is the
  queue/global-budget one (`overloaded`/503, `reason=queue_full`), not the per-tenant quota one
  (`rate_limited`/429) — both are real, contract-named shed paths (fs-06's own semantics text
  covers exactly this: "queue/global budget" shedding), just not the specific one an
  unauthenticated deployment can reach. **Documented as an expected discrepancy of the reduced
  (no-auth) topology, not a defect** — flagged in `hypothesis.md` before running, confirmed as
  predicted.
- "Accepted-request latency is protected": **matched**, on a small sample (n=3, p95=24ms vs. 20ms
  baseline).
- `inference_sheds_total{reason=queue_full}` moved as required: **matched**.

## Client impact (streaming-critical scenario, inferbench)

3/399 admitted at baseline latency, 392/399 cleanly shed (typed 503 + Retry-After, never a
connection reset or silent drop), 4/399 an unrelated timeout artifact (see above). Zero silent
failures, zero untyped errors.
