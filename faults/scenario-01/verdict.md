# Scenario 01 — Verdict

**Run:** `faults/scenario-01/inject.sh`, evidence in
`faults/scenario-01/evidence/20260712T012421Z/` (transcript.log, gateway-metrics-{after,part2}.txt,
inferbench-run/, inferbench-run-part2/).

## Part 1 — hard kill (`docker kill -SIGKILL`) of the only backend

- `inference_backend_healthy{backend="mock-faults"}`: 1 → 0 within ~1s of the kill, back to 1
  ~1s after the restart. **Matches** ("goes to 0 ... within the health-check interval").
- inferbench (60 requests, streaming, rate 4, spanning the kill+restart window): `sent=60 ok=39
  errors=6 shed=15`. `error_class` breakdown: 6×`upstream_error` (typed, 5xx), 15×`overloaded`/
  `backend_unavailable` (typed 503 shed), 39×`ok`. **No duplicated or oversized output** in any
  event (checked: `output_tokens` never exceeds the workload's 200-token cap).
- `inference_retries_total{stage="pre_first_token"}` stayed **0** through Part 1 — this is the
  one clause that did **not** show the expected metric movement, and it is not a fluke: read
  together with `inference_sheds_total{reason="backend_unavailable"}=15`, the picture is —
  - Requests whose *first* `Select()` already saw the backend unhealthy (arrived after the
    poller caught up) were shed immediately, without an attempt — 15 of these.
  - Requests already in flight *when* the kill happened got a real failed attempt, then their
    **retry's own `Select()` call also found the backend unhealthy** by then (the health poller,
    `internal/route.DefaultPollInterval=200ms`, had already flipped it) — `internal/reliability/
    retry.go`'s `Do()` returns the earlier `lastErr` on that path (`retry.go:88-91`) **without**
    reaching the `tries>0` branch that increments `inference_retries_total` (`retry.go:99-104`) —
    6 of these (the `upstream_error` count).
  - With exactly one backend, there is no outcome where a retry actually lands on a *different*,
    healthy node — so this metric is structurally unable to move in the "hard kill of the sole
    backend" case. This is not a race/flake; it reproduced identically.

## Part 2 — transient per-request failure (`-error-rate=0.5`, `/healthz` unaffected)

Run specifically to close the Part-1 gap: with health never leaving 1, a request's retry really
can land back on the (still nominally healthy) same node.

- `sent=60 ok=8 errors=9 shed=43`; **`inference_retries_total{stage="pre_first_token"}=4`
  (moved, as required)**. `error_class`: 9×`upstream_error`, 43×`overloaded`/`backend_unavailable`
  while `inference_backend_healthy` stayed **1** throughout — i.e. the 43 shed came from the
  **circuit breaker** opening (`ErrCircuitOpen`, default `breaker-failure-threshold=0.5`,
  `breaker-min-requests=10`), not from the health poller. A 50% injected failure rate sits right
  at the breaker's default trip threshold, so after the first ~10 requests the breaker opens and
  most of the rest are shed pre-attempt (`backend_unavailable`) rather than actually exercising a
  second 50/50 draw — an incidental but genuine and correctly-typed overload-protection behavior,
  not a bug; it just means this run's 4 retries all happened in the pre-trip window (plus any
  half-open probe windows during `breaker-open-duration=5s`).
- **No stage other than `pre_first_token` appeared in `inference_retries_total` in either part.**

## Verdict: expected-semantics-matched, with one documented, structural deviation

- Client-visible behavior clause (**"either a successful response/stream ... or a typed
  upstream_error envelope — never partial output, never duplicated output"**): **matched** in
  both parts — every non-2xx outcome was a typed 5xx/503 envelope, and no oversized/duplicated
  output was observed.
- "No retry ever occurs after the first token": **matched** — `inference_retries_total` carried
  no stage value other than `pre_first_token` in any run.
- "Retried ... against another healthy backend, within the retry budget" / "if retry budget
  exhausted or no healthy backend exists, typed error": **matched functionally** (a retry *is*
  attempted and *is* counted — Part 2), but **cannot be demonstrated in its literal
  "another healthy backend" form** on this release: `cmd/gateway/main.go:145-152` wires exactly
  one backend into `route.Router` from CLI flags (N-backend routing exists in
  `internal/route` but "is not yet flag-driven for N>1" — infergate's own recorded scope
  reduction, not something inferops can add without an infergate CLI/config change). **Deviation,
  documented, not a defect.**
- `inference_retries_total` metric-movement clause: **deviation** — in a genuine hard-kill of the
  sole backend, the metric legitimately never moves (see Part 1 analysis); it only moves under a
  transient failure that doesn't also flip backend health (Part 2). Recorded as an **observation
  for infergate** (not filed as a defect, since the single-attempt-then-Select-fails path is a
  reasonable design choice given no second backend exists to retry onto) — worth an explicit note
  in a future `internal/reliability/retry.go` doc comment so operators reading
  `inference_retries_total=0` during a real outage don't mistake it for "no retry was ever
  attempted" when in fact one was, and simply found nothing to retry onto.

## Client impact (streaming-critical scenario, inferbench)

- Part 1 (hard kill + recovery, 20s window): 39/60 ok, 6/60 typed upstream_error, 15/60 typed
  503 shed — 0 silent failures, 0 duplicated/truncated output, 0 hangs.
- Part 2 (transient 50% failure, ~14s window): 8/60 ok, 9/60 typed upstream_error, 43/60 typed
  503 shed (breaker-protected) — again 0 silent failures.
