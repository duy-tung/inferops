# Scenario 09 — Usage database failure

- **Contract reference:** `examples/faults/fs-09-usage-database-failure.json` (Contract 6, item
  9): make the usage/settlement database unavailable during steady traffic, then restore it.
- **Injection:** `docker stop inferops-postgres-dev` (the compose-managed dev PostgreSQL the
  main, `-auth-mode=db`, `inferops-gateway` instance actually depends on — the ONE gateway
  instance in this repo running with the usage ledger enabled; every ad hoc `gateway-faults*`
  instance used elsewhere in this campaign runs `-auth-mode=none`, which disables the DB-backed
  usage writer entirely, so this scenario cannot use them) while a steady authenticated request
  stream runs against `http://127.0.0.1:8080`, then `docker start inferops-postgres-dev` to
  restore it.
- **Expected gateway semantics (verbatim):**
  1. "Request serving is unaffected: admission, routing, and streaming never block on
     settlement — settlement is asynchronous and off the request path."
  2. "Usage records accumulate in a bounded backlog keyed by request ID during the outage."
  3. "After recovery the backlog drains idempotently: the request ID is the idempotency key for
     usage settlement, so replays neither double-bill nor lose records."
- **Expected client-visible behavior:** "None. Latency, error rate, and streaming behavior are
  indistinguishable from no-fault operation throughout the outage and the drain."
- **Metrics/observations that must move:** `usage_ledger` row count in PostgreSQL stalls during
  the outage, then catches up (grows) after recovery — checked directly via `psql`, a stronger
  signal than the Prometheus counter alone since it confirms actual durable persistence, not just
  in-memory accounting.
- **Metrics that must not move:** request success rate and latency during the outage (checked via
  direct client-side HTTP status/timing) — indistinguishable from the pre-outage baseline.
- **Abort condition (verbatim):** "Abort (and restore the database immediately) if request latency
  or error rate moves with the outage, or the settlement backlog exceeds its configured bound."
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios (and
  inferbench cannot reach this authenticated instance regardless — no Authorization header
  support); measured with direct authenticated `curl` request/latency accounting instead.
