# Campaign matrix — Contract 6 fault injection (IO-T006/T007, I7)

Twelve Contract 6 fault scenarios, executed against the running compose stack (mock-backend +
llama.cpp + dev PostgreSQL + observability, per `docker ps`). Each row links to the scenario's
`hypothesis.md` (written/reviewed before injection), `inject.sh` (re-runnable), `checklist.md`,
and `verdict.md` (full detail, exact numbers, exact quotes). Client impact for the five
inferbench-mandated scenarios (1, 2, 5, 6, 12 — docs/testing.md) is measured with a locally built
`inferbench` (commit `62c2704997e6c8a2966307ee3d8dbfd16747b631`, 2026-07-11 — no tagged release
exists yet upstream, recorded honestly as build-from-commit rather than by-digest, the released-
artifacts rule's closest available match for a tool with no release process yet).

All 12/12 scenarios executed. Kill-criteria set (1, 2, 5, 6, 11, 12) fully run; no scope
reduction was needed.

| # | Scenario | Injected | Observed | Verdict | Metrics that moved | Client impact |
|---|---|---|---|---|---|---|
| 1 | Backend killed before first token | `docker kill -SIGKILL` on the sole backend (hard-kill part) + `-error-rate=0.5` transient-failure part | Hard kill: health 1→0→1 (restart), 6 typed `upstream_error`, 15 typed 503 shed, 0 dup/oversized output, `retries_total` stayed 0 (structural — see verdict). Transient: `retries_total` moved to 4 (retry mechanism confirmed working); circuit breaker opened under sustained 50% error rate. | **expected-semantics-matched, 1 documented deviation** (no 2nd backend to retry onto — IG-T012 not flag-driven for N>1, infergate's own recorded scope reduction) | `inference_backend_healthy` 1→0→1; `inference_retries_total{pre_first_token}` 0 then 4; `inference_requests_total{error_class=upstream_error}` | Part1: 39 ok/6 err/15 shed of 60. Part2: 8 ok/9 err/43 shed of 60. 0 duplicated/silent failures. |
| 2 | Backend killed after first token | `docker kill -SIGKILL` on the sole backend, ~1.5s into concurrent streams (all past their 100ms TTFT) | Captured raw SSE stream shows a **verbatim-matching** mid-stream error event (`type=upstream_error`, "never retried... billable"); population: 5 clean typed errors, `usage_tokens_total{output}` +1796 (partial usage settled), 0 retries, 0 duplicate request IDs | **expected-semantics-matched** | `inference_requests_total{error_class=upstream_error}`; `inference_usage_tokens_total{direction=output}` (0→1796); `inference_retries_total` stayed 0 (correctly — no post-first-token retry, ever) | 51 ok/5 clean-typed-error/3 shed/1 unexplained-benign-timeout of 60. 0 hangs, 0 duplicated output. |
| 3 | Slow backend | `mock-faults -ttft` raised (1.5s within-budget, 3s over-budget vs. tightened `-ttft-timeout`) | Part A: 8/8 succeed at ~1.73s (elevated, bounded); Part B: 8/8 typed HTTP 504 `upstream_timeout` at ~1.51s; `inference_backend_healthy` stayed 1 through 100% timeout rate in Part B | **expected-semantics-matched, 2 documented deviations** (no routing-shift possible — single backend; mock exposes no Contract-4 `queue_waiting_requests` signal) | `inference_backend_healthy` (stayed 1); `inference_requests_total{error_class=upstream_timeout}` (0→8) | not inferbench-mandated; direct curl timing, both parts clean and bounded |
| 4 | Slow client | Raw stalled TCP socket (zero reads, shrunk receive window, 8s stall vs. 3s configured `-stream-write-timeout`) + inferbench `slow-client` workload | Stream was **NOT closed** by the gateway during an 8s full stall (2.6x the deadline) — resumed normal delivery once reads resumed and completed successfully; inferbench population: 3 slow streams completed late (12-22s), 6 ran to inferbench's own 60s client timeout — none cut by the gateway at ~3s | **deviation-documented** (not matched) — matches infergate's own `internal/stream/relay.go` comment: "Full slow-client fault handling — scenario 4 — is later work; the bound exists now." Recorded as an **observation for infergate**, not a hidden defect. | `inference_requests_in_flight` returned to 0 (trivially — everything eventually completed, nothing to recover from) | No slow client was ever cut off early; normal-speed clients unaffected throughout |
| 5 | Gateway termination during streaming | `docker kill -SIGTERM` on one of two fleet replicas mid-stream, 2s into a continuous inferbench run; **cites and re-confirms** `scripts/drain-test.sh` (IO-T004) | Terminating replica stopped accepting new work and exited cleanly on its own (never force-killed); the other replica kept serving throughout | **expected-semantics-matched** | replica's own `/readyz` flipped non-200 immediately; aggregate capacity never dropped | **60/60 ok, 0 errors** (inferbench) |
| 6 | Queue saturation | Tightened admission (`-admission-tenant-queue-cap=4 -admission-global-inflight-budget=4 -admission-global-queue-cap=8`) + `fault-bursty.json` burst (2→25 rps) | Manual burst: clean typed 503 + `Retry-After: 1` + request ID for every shed request; inferbench: `sent=399 ok=3 errors=4 shed=392`, admitted-population TTFT p95=24ms (~baseline) | **expected-semantics-matched, 1 documented (expected) discrepancy** (no-auth topology reaches the queue/global-budget 503 shed path, not the per-tenant `rate_limited`/429 path — both are real contract-named shed paths, just not the one an unauthenticated deployment can reach) | `inference_sheds_total{reason=queue_full}` (0→408); admitted TTFT stayed at baseline | **3/399 admitted at baseline latency, 392/399 cleanly typed-shed, 0 silent drops** (inferbench) |
| 7 | Retry storm | `mock-faults -error-rate=0.3` + 10 concurrent no-backoff client workers, 15s, two admission configs (moderate, then tight) | Part 1: retries/total = **0.100**, exactly the configured `retry-budget-ratio=0.1`. Part 2 (tight admission): 88% of offered load shed (`queue_full`), retries/dispatched still ≈0.098 | **expected-semantics-matched, 1 documented deviation** (single-backend — "non-injected backend stays healthy" clause N/A) | `inference_retries_total` (bounded to ~0.1x dispatched in both configs); `inference_sheds_total{queue_full}` (0→4450 in Part 2) | not inferbench-mandated; aggressive-fleet accounting (the literal mechanism named), 0 untyped errors |
| 8 | Config reload during traffic | Publish new gateway config (new model alias) then rollback, under continuous traffic; **cites and re-confirms twice** `scripts/config-rollout.sh` (IO-T010) | 3 independent runs (1 original + 2 fresh): **0 dropped requests every time** (71 short + 12 stream total across all runs), `config_version` v1→v7 monotonically, swap latency in the hundreds of µs | **expected-semantics-matched** (strongest-evidenced scenario in the campaign) | `config_version` advanced each run; `inference_requests_total{2xx}` kept climbing through every swap | 0/71 short + 0/12 stream dropped, cumulative |
| 9 | Usage database failure | `docker stop`/`start` on `inferops-postgres-dev` under continuous authenticated traffic (main `-auth-mode=db` gateway) | 35/35 requests succeeded at **identical** ~120ms latency across before/during/after; `usage_ledger` row count +35 exactly (0 lost), 0 duplicate settlements | **expected-semantics-matched** (cleanest, most unambiguous result in the campaign) | PostgreSQL `usage_ledger` row count (123→158, matching total requests); request latency/success rate unchanged | 35/35 requests succeeded through a real ~3s DB outage; 0 measurable effect |
| 10 | One unhealthy backend | `docker pause`/`unpause` on the sole backend (freezes `/healthz` too, unlike `-error-rate`) under a background probe stream | health 1→0→1 observed directly; 17 fast typed 503s (~11ms) once health flipped; 3 in-flight-at-pause requests hung until the client's own timeout (pause-vs-fail-fast nuance, recorded) | **expected-semantics-matched, 2 documented deviations** (no routing-shift — single backend; pause causes a hang for the in-flight-at-injection population rather than a fast typed error, an artifact of the chosen injector) | `inference_backend_healthy` 1→0→1; `inference_sheds_total{backend_unavailable}` (0→18) | 10/10 baseline, 17 fast typed shed + 3 client-side-timeout during the outage, 29/30 recovered immediately after unpause |
| 11 | Readiness during model warm-up | 12s injected mock-backend startup delay vs. a simulated 20s startup-probe budget; **cites and re-confirms twice** `scripts/warmup-readiness-test.sh` (IO-T004) | 3 independent runs, **5/5 passed every time**: `/healthz` failed repeatedly pre-warm, `inference_backend_healthy` 0→1 exactly once, mid-warm-up request got a definitive typed 503, post-warm-up request succeeded, `RestartCount=0` every run | **expected-semantics-matched** | `inference_backend_healthy` (0 through warm-up, 1 after); container `RestartCount` (0 every run) | every in-window request got a typed 503 (never silent/hang); every post-warm-up request succeeded |
| 12 | Rolling update with active requests | Sequential drain+replace of both fleet replicas under a continuous streaming inferbench population; **cites and re-confirms** `scripts/rolling-update-test.sh` (IO-T004, 0/27+0/3 curl-based) | Both replicas drained cleanly (SIGTERM, self-exit) and were replaced/re-admitted only once ready | **expected-semantics-matched** | replica `/readyz` transitions observed at each roll step; aggregate capacity never zero | **60/60 ok, 0 errors** (inferbench), plus IO-T004's independent 0/27+0/3 curl-based confirmation |

## Coverage summary

- **12/12 scenarios executed** — no scope reduction triggered; the never-cut streaming-critical
  set (1, 2, 5, 6, 11, 12) all ran in full, with inferbench client-impact numbers for 1, 2, 5, 6,
  12 as required.
- **11/12 verdicts: expected-semantics-matched** (6 fully clean: 2, 5, 8, 9, 11, 12; 5 matched with documented non-defect deviations: 6\*, 7\*, and 1\*/3\*/10\*
  matched with documented, non-defect deviations — marked `*` below).
- **1/12 verdict: deviation-documented (a real observation, not matched)** — **scenario 4** (slow
  client / write-deadline enforcement). This is the campaign's one finding that reads as a defect
  rather than a topology limitation, though it corroborates something infergate's own source
  already flags as incomplete (`internal/stream/relay.go`: "Full slow-client fault handling —
  scenario 4 — is later work; the bound exists now"). See scenario 4's `verdict.md` for the full
  reproduction and root-cause hypothesis.
- **Documented, non-defect deviations** (all traced to one recorded, upstream-acknowledged cause):
  scenarios 1, 3, 7, 10 cannot demonstrate multi-backend routing-shift because this release's
  `cmd/gateway/main.go` wires exactly one backend into `route.Router` from CLI flags — IG-T012
  N-backend routing exists in `internal/route` but "is not yet flag-driven for N>1"
  (`cmd/gateway/main.go:145-152`, infergate's own recorded scope reduction). Scenario 6 reaches
  the queue/global-budget 503 shed path rather than the per-tenant `rate_limited`/429 path because
  it runs `-auth-mode=none` (required so `inferbench` — which sends no `Authorization` header —
  can drive it). Scenario 10's `docker pause` injector produces a hang rather than a fail-fast
  error for the handful of requests in flight at the exact injection instant (a property of the
  chosen injection method, not the gateway).

## Observations filed against infergate (for the record; not fixed here — out of scope per the
program's repo-ownership rule)

1. **Scenario 4 (slow client): `-stream-write-timeout` did not close a genuinely stalled stream**
   across an 8-second stall (2.6x the configured 3s deadline) in this deployment. Infergate's own
   `internal/stream/relay.go` already documents this as partial ("the bound exists now," full
   handling "later work") — this campaign's finding is a real, reproducible confirmation of that
   gap at the deployed-binary level, worth a concrete follow-up task (investigate whether
   `http.ResponseController.SetWriteDeadline` is silently returning `http.ErrNotSupported` for
   this server configuration — the code's own error handling tolerates that silently, which makes
   "deadline set but never fires" and "deadline silently unsupported" indistinguishable from
   outside the process).
2. **Scenario 1: `inference_retries_total` does not increment when a retry's own `Select()` call
   also fails** (e.g. health flipped between the first attempt and the retry) — `retry.go`'s
   `Do()` returns the earlier error via the `lastErr != nil` branch without ever reaching the
   `tries>0` metrics-increment code. Not a functional defect (there is nothing useful to retry
   onto once `Select` itself fails) but worth a doc-comment note so operators reading
   `inference_retries_total=0` during a real single-backend outage don't mistake "no retry fired"
   for "a retry was never attempted."
3. **IG-T012 (N-backend routing) has no CLI/config exposure yet** in the released gateway binary
   — `route.Router` supports it internally (tested), but `cmd/gateway/main.go` always constructs
   exactly one `BackendSpec`, and the `-config` file schema's `fallback` nesting is explicitly
   one level only. This blocks a fully faithful reproduction of fs-01/03/07/10's multi-backend
   routing-shift clauses from any consumer repo. Already self-recorded by infergate as a scope
   reduction — surfaced here as a concrete consumer (this campaign) that would benefit from it
   landing.

## Noisy-neighbor observation run (IO-T007 extra, not one of the 12 scenarios)

`faults/noisy-neighbor/` — tenant A (`default` tier, 200 concurrent) vs. tenant B (`gold` tier,
steady trickle) against the main `-auth-mode=db` gateway. Tenant B stayed at baseline latency
(p50 122ms/p95 126ms) throughout tenant A's flood (which itself absorbed p50 726ms/p95 1.32s of
queueing delay) — tier isolation observed at the ops level, not tuned. Full detail:
`faults/noisy-neighbor/notes.md`.

## Postmortem-style scenarios (candidates for the ≥2 I7 postmortems, written up separately in
inference-lab)

Scenario 4 (slow client) and scenario 1 Part 1 (single-backend hard-kill's `retries_total`
non-movement) are the two scenarios with a real "timeline → detection gap → root cause →
mitigation" story worth a full postmortem write-up; scenario 9 (usage DB failure) is the strongest
"nothing went wrong, exactly as designed" counter-example worth pairing with them.
