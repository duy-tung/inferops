# Scenario 10 — Verdict

**Run:** `faults/scenario-10/inject.sh` (second attempt — the first used a sequential probe loop
where one blocked request starved the whole pause window of samples; fixed to launch each probe
as an independent background job), evidence in
`faults/scenario-10/evidence/20260712T015439Z/` (`probe.csv`, `gateway-metrics-after.txt`).

## Observed

Probe timeline (background jobs, ~150ms cadence, pause at t=1.5s, unpause at t=4.5s):

| Window | Codes |
|---|---|
| before (t<1.5s) | `200` x10 |
| during (1.5s-4.5s) | `503` x17, `000` (client-side timeout) x3 |
| after (t>4.5s) | `200` x29, `503` x1 (one straggler right at the recovery instant) |

- `inference_backend_healthy{backend="mock-faults"}`: 1 → 0 (confirmed at t+2.3s into the pause)
  → 1 (confirmed after unpause) — health detection and recovery both directly observed.
- The 3 `000` (client-timeout) requests were the ones already in flight **at the exact pause
  instant** — these hung rather than failing fast: `docker pause` freezes the whole process
  (including connection handling), so a request already dispatched just sits until *something*
  gives up. The gateway itself classified these as `inference_requests_total{...,
  error_class="canceled"}` (×3, matching exactly) once *my client's* 1.2s timeout closed the
  connection — the gateway's own `upstream-timeout` default (30s) is far longer, so absent my
  own client bailing out it would have kept waiting well past this window.
- The 17 `503` responses landed at a **fast, consistent ~11ms** — the post-health-flip shed path
  (`inference_sheds_total{reason="backend_unavailable"}=18` — 17 during + 1 straggler after),
  confirming the gateway does NOT keep dialing a backend it already believes is down.
- `inference_retries_total` stayed 0 throughout — the same structural reason established in
  scenario 01's verdict (single node: once `Select()` sees zero healthy nodes it returns
  `ErrNoBackendAvailable` immediately, never reaching the retry-count increment).

## Verdict: expected-semantics-matched, with two documented deviations

- "`inference_backend_healthy` goes to 0 within the bounded detection interval, recovers on
  probes succeeding again": **matched** — directly observed both transitions.
- "Only probe traffic reaches [the unhealthy backend] while open" / "requests fail fast": **partial
  match, one nuance recorded** — this campaign's chosen injection (`docker pause`, needed so
  `/healthz` itself also fails, unlike the `-error-rate` mechanism used elsewhere) makes the
  backend **hang** rather than **fail fast**, which differs from fs-10's literal injection
  description ("all requests fail fast with errors"). The 3 requests caught in the stale window
  hung until *my own client's* timeout rather than receiving a fast typed error from the gateway
  — an artifact of the injection method (pause vs. error-inject), not evidence the gateway
  mishandled it (it correctly recorded them as canceled once the client actually left). Getting
  BOTH "fails `/healthz` too" and "fails each request instantly" simultaneously would need a
  network-level reject (e.g. `iptables REJECT` for the container, out of this campaign's simplest-
  injector-first scope) rather than a process-level signal — recorded as a scope note, not a
  gateway defect.
- Once health flipped, subsequent requests **did** fail fast (503 in ~11ms) — the "only probe
  traffic reaches it" half of the clause is confirmed for the post-detection period.
- "Routing shifts away ... to healthy backends": **not demonstrable** — same single-backend
  reduced-form limitation as scenarios 01/03/07 (`cmd/gateway/main.go:145-152`). **Documented
  deviation, not a defect.**
- `inference_retries_total` movement: same structural non-movement as scenario 01 (cross-
  referenced there, not re-derived) — a single-node deployment's retry-select has nothing to
  retry onto once health flips, so the counter legitimately stays flat.

## Client impact

10/10 baseline, then during the ~3s pause: 17 fast typed 503s + 3 requests that hung until the
client's own timeout (a consequence of the pause-based injection method, not a silent failure —
each was accounted for as `canceled` server-side). 29/30 recovered immediately after unpause, one
straggler right at the recovery instant. No untyped errors, no hangs past the client's own bound.
