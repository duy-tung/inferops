# Runbook: Database Outage

**Evidence base:** fault scenario 9 (usage database failure), `faults/scenario-09/{inject.sh,
verdict.md,checklist.md}`; IO-T004's `-auth-mode=db` startup finding
(`docs/implementation-notes.md` "2026-07-11 — IO-T004 executed").

## Symptoms / Trigger

The usage-ledger PostgreSQL instance (`inferops-postgres-dev` in compose; the dev-PostgreSQL
StatefulSet in the Kustomize base) becomes unreachable — network partition, container/pod
restart, host issue.

## Preconditions / which gateway instance is affected

**This only matters for `-auth-mode=db` gateway instances.** The main compose `gateway` service
runs `-auth-mode=db` and genuinely depends on PostgreSQL for tenancy/auth and the usage ledger.
`-auth-mode=none` instances (`gateway-llamacpp`, every fault-campaign throwaway gateway in
`faults/lib.sh`) have **no** database dependency at all — a PostgreSQL outage is a complete
non-event for them. Confirm which instance is in scope before doing anything.

There are two operationally distinct cases:

- **Case A — DB goes down while the gateway is already running and warm.** Per fault scenario 9's
  measured result, this is a non-event for request serving.
- **Case B — DB is down at gateway container/pod startup (or restart).** This is a real, load-
  bearing constraint: `config.OpenDBStore` performs exactly **one** `PingContext` + one `Reload` at
  startup; either failing returns an error and `main()` calls `os.Exit(2)` — **there is no internal
  retry/backoff loop.** The deployment-contract's `expected_warm_up_seconds`/startup budget
  describes how long this one-shot sequence takes to *complete*, not a window during which the
  process internally waits for a not-yet-ready database.

## Diagnosis

1. Confirm the DB is actually down:
   ```
   docker exec inferops-postgres-dev pg_isready -U infergate -d infergate
   ```
   Kubernetes equivalent: `kubectl exec <postgres-pod> -- pg_isready -U infergate -d infergate`.
2. Confirm whether the gateway is already running (Case A) or is currently trying to
   start/restart (Case B) — `docker inspect --format='{{.State.Status}}' inferops-gateway` /
   `kubectl get pod <gateway-pod>`. A gateway stuck in a restart loop with exit code 2 during a DB
   outage is Case B, expected given the no-internal-retry behavior above — not a separate bug.
3. For Case A, confirm request serving is genuinely unaffected: send a real authenticated request,
   expect HTTP 200 at baseline latency (~120ms for this repo's dev topology). This is the key
   differentiator from Case B.

## Mitigation

### Case A — DB down, gateway already running

**No action required on the request path.** Usage settlement records queue in a bounded backlog
in-memory and drain automatically once the DB returns, keyed by request ID for idempotent replay.
Recovery steps, once the underlying cause of the DB outage is addressed:
```
docker start inferops-postgres-dev
# wait for readiness:
docker exec inferops-postgres-dev pg_isready -U infergate -d infergate
```
Then confirm the backlog actually drained:
```
docker exec inferops-postgres-dev psql -U infergate -d infergate -tA \
  -c "SELECT count(*) FROM usage_ledger;"
```
Row count should catch up to (pre-outage count + total requests sent, including those sent while
the DB was down) within seconds of the DB coming back — this repo's measured recovery was **within
1 second**. Then run the idempotency spot-check:
```
docker exec inferops-postgres-dev psql -U infergate -d infergate -tA -c \
  "SELECT request_id, count(*) FROM usage_ledger GROUP BY request_id HAVING count(*) > 1 LIMIT 5;"
```
Expect **0 rows** — any duplicate `request_id` here is a double-settlement (billing-correctness)
defect, escalate immediately (see Escalation).

### Case B — DB down at gateway startup/restart

1. Ensure PostgreSQL is healthy **and schema-migrated** first — do not attempt to start the
   gateway against a DB that is merely reachable but unmigrated (`scripts/bootstrap-dev-db.sh`'s
   own ordering already enforces this: postgres-dev healthy → schema applied → gateway started).
2. Only then start/restart the gateway:
   ```
   docker compose --profile app up -d gateway
   ```
   Kubernetes note: the orchestrator's restart policy will keep retrying pod starts, but **each
   individual attempt still fails fast** rather than internally waiting — an extended DB outage at
   startup time means an extended crash-loop until the DB returns, not a graceful wait. This is a
   documentation-accuracy candidate already filed against the deployment-contract descriptor's
   `warm_signal` prose (see `docs/implementation-notes.md`'s IO-T004 entry) — know it going in
   rather than being surprised by a `RestartCount` climbing during a real DB outage.

## Verification

- `/readyz` returns 200 on the gateway.
- A real authenticated request succeeds (HTTP 200).
- `usage_ledger` row count matches the expected total (pre-outage + all requests sent during and
  after).
- 0 duplicate `request_id` rows in `usage_ledger`.

## Escalation

- **Backlog does not drain after the DB comes back** (row count stays flat) → a real defect in the
  settlement-drain loop, escalate to infergate.
- **Duplicate `request_id` rows found** → an idempotency defect — escalate immediately as a P1
  (double-billing risk), independent of anything else in this runbook.
- **Case B: gateway keeps crash-looping well after the DB is confirmed healthy and migrated** → not
  a database-outage issue anymore; check DSN/secret correctness (`docs/security.md` §1's rotation
  section — a DSN rotated without restarting/updating the gateway will look exactly like "the DB
  is down" from the gateway's perspective) before escalating further.

## Walkthrough

**Case A — live-cited.** `faults/scenario-09/evidence/20260712T015241Z/`: `docker stop
inferops-postgres-dev` at 01:52:43Z, `docker start` (restore) at 01:52:46Z — a real ~3-second
outage with traffic sent throughout (not just at the edges). Result: **35/35 requests succeeded**
at identical ~120ms latency across all three phases (before/during/after) — not merely similar,
identical to the millisecond. `usage_ledger` row count: 123 → 158 (+35, exactly matching every
request sent, including the 15 sent while the DB was fully down), fully drained within 1 second of
restoration. Idempotency spot check: **0 duplicate `request_id` rows.** Described in the campaign
matrix as "the cleanest, most unambiguous result in the campaign."

**Case B — tabletop.** IO-T004's finding that `-auth-mode=db` startup performs exactly one
`PingContext`+`Reload` with no internal retry (`os.Exit(2)` on failure) is a real, reproducible
finding from direct interface-level source reading (`git show`, no application code copied), not
an assumption — but this session did not independently re-trigger it by crashing the gateway's DB
dependency at container-start time. Recorded honestly as tabletop for this half of the runbook only.
