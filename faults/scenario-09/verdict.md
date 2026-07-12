# Scenario 09 — Verdict

**Run:** `faults/scenario-09/inject.sh`, evidence in
`faults/scenario-09/evidence/20260712T015241Z/` (`requests.csv`, `duplicate-check.txt`,
`transcript.log`).

## Observed

- `docker stop inferops-postgres-dev` at 01:52:43Z; `docker start` (restore) at 01:52:46Z (~3s
  outage; traffic sent throughout, not just at the edges).
- Client-side request record across all three phases (35 requests total): **`before n=10
  codes={200:10}` wall 0.120-0.121s; `during n=15 codes={200:15}` wall 0.120-0.121s; `after n=10
  codes={200:10}` wall 0.120-0.123s.** Latency and success rate during the DB outage are
  **indistinguishable** from before/after — not merely "similar," identical to the millisecond.
- `usage_ledger` row count: 123 (before) → 158 (measured 1s after DB restoration) — **+35, exactly
  matching the total requests sent across all three phases**, including the 15 sent while the DB
  was fully down. The backlog (15 records held only in memory during the ~3s outage) drained
  completely within 1 second of the DB coming back.
- Idempotency spot check: `SELECT request_id, count(*) FROM usage_ledger GROUP BY request_id
  HAVING count(*) > 1` returned **0 rows** — no double-settlement.

## Verdict: expected-semantics-matched

Every clause confirmed directly and cleanly:

- "Request serving is unaffected ... never blocks on settlement": **matched** — identical latency
  and 100% success rate through the outage.
- "Usage records accumulate in a bounded backlog ... keyed by request ID": **matched** — all 15
  in-outage requests' usage records appeared after recovery, none lost.
- "Backlog drains idempotently ... replays neither double-bill nor lose records": **matched** —
  0 duplicate `request_id` rows, and the row-count delta (+35) exactly accounts for every request
  sent (0 lost).

No deviation to record — this is the cleanest, most unambiguous result in the campaign.

## Client impact

35/35 requests succeeded at baseline latency (~120ms) across the entire before/during/after
window; zero client-visible effect of a real ~3-second database outage.
