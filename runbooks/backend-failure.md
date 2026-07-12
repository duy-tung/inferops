# Runbook: Backend Failure

**Evidence base:** fault scenarios 1 (backend killed before first token), 2 (backend killed after
first token), 10 (one unhealthy backend); `faults/scenario-{01,02,10}/{inject.sh,verdict.md}`;
`faults/campaign-matrix.md`.

**SRE overload/cascading-failures lens applied** per `docs/tasks.md` IO-T008 /
`docs/experiments.md` §4.

## Symptoms / Trigger

- `inference_backend_healthy{backend=...}` drops to 0 on the golden dashboard.
- A spike in `inference_requests_total{...,error_class="upstream_error"}` or
  `inference_sheds_total{reason="backend_unavailable"}`.
- The "Backend unhealthy" alert sketch (`docs/observability.md` §7:
  `inference_backend_healthy == 0` sustained) fires.

## Preconditions / load-bearing constraint to know before touching anything

**This release's gateway wires exactly one backend into `route.Router`** —
`cmd/gateway/main.go:145-152` constructs a single `BackendSpec` from CLI flags; IG-T012 N-backend
routing exists internally but is not yet flag-driven for N>1 (infergate's own recorded scope
reduction, confirmed across fault scenarios 1, 3, 7, 10). **There is currently no automatic
failover target in this deployment** — do not assume "the gateway will route around it." A fully
down backend with no standby means the request path itself is down until the backend (or a
second one, if the deployment is ever grown past one) recovers.

## Diagnosis

1. Check `inference_backend_healthy{backend="..."}` via Prometheus/the golden dashboard — 0 means
   the router's health poller (200ms interval, `internal/route.DefaultPollInterval`) has marked it
   down.
2. Distinguish *when* the backend died relative to in-flight requests — the gateway's semantics
   differ by phase (Contract 6):
   - **Pre-first-token kill (scenario 1):** requests in flight either retry-and-fail typed
     (`upstream_error`) or succeed after recovery — never partial/duplicated output.
   - **Post-first-token kill (scenario 2):** already-streaming requests get a standardized SSE
     error event (`type=upstream_error`, "never retried... billable") and are **never retried** —
     partial output is settled as usage, not discarded.
   - **Unhealthy-but-not-fully-dead (scenario 10):** once health flips, subsequent requests fail
     fast (503, ~11ms observed) — this is the router correctly refusing to keep dialing a backend
     it already believes is down, not a hang.
3. Check gateway logs for the concrete failure signature (`docker logs <gateway>` /
   `kubectl logs`).
4. **Do not use `inference_retries_total` staying at 0 as evidence retries "aren't working."** A
   real, structural finding from this campaign: in a genuine hard-kill of the *sole* backend, a
   retry's own `Select()` call also finds no healthy backend and returns the earlier error without
   reaching the metrics-increment code (`internal/reliability/retry.go` `Do()`,
   `lastErr != nil` branch) — there is nothing to usefully retry onto with one backend. The retry
   mechanism itself is confirmed working under a *transient* (non-health-flipping) failure rate
   (scenario 1 Part 2: `inference_retries_total{stage=pre_first_token}` moved from 0 to 4 under a
   50% transient error rate that never touched `/healthz`).

## Mitigation

- For a hard-down backend: restart it. `docker restart <backend-container>` /
  `kubectl delete pod <backend>` (letting the controller reschedule it). **No manual gateway
  restart is required** — the health poller self-heals routing once the backend responds again;
  measured recovery: health flips 0→1 within ~1s of the backend coming back (scenario 1), and a
  post-recovery request succeeds immediately.
- If the backend keeps crash-looping after restart, this is an application-level defect in the
  backend/engine itself — escalate to the owning component (infergate's backend adapter, the mock
  engine, vLLM, or llama.cpp), not an inferops-side fix.

## SRE overload/cascading-failures lens

- **Retry amplification:** the gateway's retry budget bounds retries to a fixed fraction of
  dispatched volume (`retry-budget-ratio`, measured at exactly **0.100** against a configured 0.1
  in fault scenario 7, across two very different admission configurations) — retries do **not**
  amplify load onto an already-struggling backend regardless of client hammer rate. **Do not add
  ad hoc client-side retry loops during an incident** — they bypass this budget entirely and can
  turn a single-backend outage into a genuine retry storm the gateway's own protection was
  specifically designed to prevent.
- **Load shedding:** once a backend is marked unhealthy, excess requests are shed **fast and
  typed** (503 in ~11ms, scenario 10) rather than queued or force-dialed — this is the intended
  pressure valve. Sustained shedding during an outage is an expected symptom to alert on (shed-rate
  spike alert, `docs/observability.md` §7), not itself evidence of a worse failure as long as sheds
  stay correctly typed (never a hang, never a silent drop).
- **Cascade containment — the circuit breaker is part of this design, not a bug to work around:**
  under a 50% transient failure rate, the breaker opens after roughly 10 requests
  (`breaker-failure-threshold=0.5`, `breaker-min-requests=10`) and sheds most subsequent requests
  pre-attempt (`backend_unavailable`) rather than continuing to hammer a failing backend
  (`breaker-open-duration=5s` before a half-open probe). **During an incident, do not disable or
  bypass the breaker** to "let more traffic through" — doing so removes exactly the mechanism that
  keeps a degraded backend from being driven further into failure by continued dispatch.
- **Single-backend topology is itself a cascade-containment gap to know about, not assume away:**
  because there is no second backend to fail over to, a genuinely down backend with no standby is
  operationally equivalent to a capacity shortfall (see `capacity-shortfall.md`) — the fix is
  restoring the one backend (or, for a deployment grown past one, standing up a second), not
  waiting for automatic routing-shift that this release cannot yet perform.

## Verification

- `inference_backend_healthy{backend=...}` back to 1.
- A real probe request (`curl -X POST .../v1/chat/completions`) succeeds with HTTP 200.
- Error/shed rate returns to baseline on the golden dashboard.

## Escalation

- Backend does not recover after restart / crash-loops → escalate to the owning component's
  on-call; this is not an inferops-layer fix.
- The outage is actually a database dependency (e.g. the backend's own state store, not the usage
  ledger) → see `database-outage.md` if PostgreSQL is implicated; otherwise treat as a distinct
  backend-owned incident.
- Repeated single-backend outages with real business impact → this is the concrete case for
  prioritizing IG-T012 (N-backend routing, CLI/config-exposed) upstream — already filed as an
  observation against infergate (`faults/campaign-matrix.md` "Observations filed against
  infergate", item 3).

## Walkthrough

**Live-cited.** All three scenarios executed 2026-07-12 against the real compose stack with
`inferbench`-measured client impact:

- **Scenario 1** (`faults/scenario-01/evidence/20260712T012421Z/`): Part 1 hard-kill — health
  1→0→1 within ~1s of kill/restart; 39/60 ok, 6/60 typed `upstream_error`, 15/60 typed 503 shed,
  0 duplicated/oversized output. Part 2 transient 50% failure — `inference_retries_total` moved
  0→4 (retry mechanism confirmed), circuit breaker opened under sustained failure.
- **Scenario 2** (`faults/scenario-02/evidence/20260712T012838Z/`): a directly captured raw SSE
  stream shows a verbatim-matching mid-stream error event; population 51/60 unaffected, 5/60 clean
  typed mid-stream error with partial usage billed, 0 duplicate request IDs.
- **Scenario 10** (`faults/scenario-10/evidence/20260712T015439Z/`): health 1→0→1 directly
  observed; 17 fast typed 503s (~11ms) once health flipped; 3 in-flight-at-pause requests hung
  until the client's own timeout (a `docker pause` injection artifact, not a gateway defect — see
  the verdict for the fail-slow-vs-fail-fast nuance); 29/30 recovered immediately after unpause.
