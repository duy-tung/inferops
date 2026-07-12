# Scenario 11 — Verdict

**Runs:** `faults/scenario-11/inject.sh` (delegates to `scripts/warmup-readiness-test.sh`),
evidence in `scripts/evidence/warmup-readiness-20260712T015535Z/` and
`scripts/evidence/warmup-readiness-20260712T015636Z/` (two fresh re-confirmations for this
campaign), plus the original `scripts/evidence/warmup-readiness-20260711T235223Z/` (IO-T004).

## Observed (three independent runs)

All three runs: **5/5 passed**, identical shape each time —

- `/healthz` failed 5 times before the delayed mock-backend came up at t=13s, comfortably inside
  the simulated 20s startup-probe budget (period=2s × failure_threshold=10).
- A request sent at t=3s (deep in warm-up) got a definitive, typed 503
  (`{"error":{"type":"overloaded","param":"backend_unavailable",...}}`) — never a silent success,
  never a hang.
- `inference_backend_healthy{backend="mock"}` stayed 0 through warm-up and flipped to 1 exactly
  once, observed directly via Prometheus-style `/metrics` queries at each run.
- A request sent after warm-up completed succeeded normally (HTTP 200).
- The container's `RestartCount` stayed **0** in every run — a startup delay, never a
  crash-restart loop.

## Verdict: expected-semantics-matched

- "Readiness false throughout warm-up; no traffic routed before warm": **matched** — repeatably.
- "Startup-probe budget covers worst-case load; liveness never kills a loading replica": **matched**
  — `RestartCount=0` across all three runs.
- "Capacity ramps only when the replica reports warm": **matched** — the post-warm-up request
  succeeded immediately once health flipped.

No deviation to record beyond the single-replica-pool reduced form already noted at IO-T004 (one
backend total in this deployment, so "no client-visible errors" during warm-up necessarily means
"a typed, honest 503" rather than literally zero client impact — the strongest honest outcome
available without a second, already-warm replica in the pool).

## Client impact

Across three runs (15 total warm-up-window checks): 0 silent successes, 0 hangs, 0 restart loops —
every in-window request got a definitive typed 503; every post-warm-up request succeeded.
