# Scenario 09 — Observation checklist

- [ ] Baseline `usage_ledger` row count recorded before the outage.
- [ ] `docker stop inferops-postgres-dev` issued; timestamp recorded.
- [ ] Requests during the outage (authenticated, against the main gateway) keep succeeding
      (HTTP 200) at baseline latency — checked directly, not assumed.
- [ ] `usage_ledger` row count stays flat during the outage (no writes reaching the DB — it's
      down).
- [ ] `docker start inferops-postgres-dev` issued; gateway's DB pool recovers without a restart.
- [ ] `usage_ledger` row count catches up (increases) after recovery, draining the backlog.
- [ ] No duplicate settlement for the same request ID after recovery (idempotency spot-check).
- [ ] Verdict recorded; campaign-matrix row written.
