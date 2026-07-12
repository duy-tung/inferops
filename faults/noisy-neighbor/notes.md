# Noisy-neighbor observation run — notes

**Run:** `faults/noisy-neighbor/inject.sh`, evidence in
`faults/noisy-neighbor/evidence/20260712T020312Z/` (`tenant-a.csv`, `tenant-b.csv`,
`transcript.log`). Tenant B (`tenant-b-gold`, tier `gold`) created via the gateway's own admin API
(`POST /admin/v1/tenants` + `POST /admin/v1/tenants/{id}/keys`, loopback-only,
`docs/security.md` §4) against the shared `postgres-dev` tenant registry the main
`-auth-mode=db` gateway already uses (the same registry `scripts/bootstrap-dev-db.sh` seeded
`smoke-tenant`, tier `default`, into).

## Observed

| Population | n | HTTP codes | wall p50 | wall p95 | wall max |
|---|---|---|---|---|---|
| Tenant A (`default` tier, 200 concurrent — the noisy one, well above `admission-global-inflight-budget=128`) | 200 | 200×200 | 0.726s | 1.317s | 1.500s |
| Tenant B (`gold` tier, 10 sequential, steady trickle throughout the same window) | 10 | 200×10 | **0.122s** | **0.126s** | 0.326s |

Tenant B's latency (~122ms p50, matching the mock's own baseline `ttft=20ms` +
network/relay overhead) is **essentially unaffected** by tenant A's 200-request flood — tenant A
itself absorbed the queueing delay (p50 0.73s, p95 1.3s) while tenant B stayed at baseline.
`internal/admission/fairness.go`'s `DefaultTierPriority` maps any tier name containing `"gold"`
to priority class 0 (high); `default` (an exact match on none of the high-priority substrings)
maps to class 1 (low) — this is exactly the isolation the priority + WRR + aging dispatch
(IG-T011) is designed to produce, observed here rather than tuned.

**Labeling quirk noted, not chased further:** the `inference_queue_wait_seconds` histogram's
`tenant_tier` label recorded tenant B's 10 requests under `tenant_tier="unknown"` rather than
`"gold"` (count matches exactly: 10). This looks like the Contract 2 cardinality policy
restricting `tenant_tier` to a small enumerated label set that doesn't include arbitrary tier
names like `gold` — worth a follow-up look at the metrics vocabulary's tier-label mapping, but it
does not affect this run's core finding (the *admission/dispatch* behavior correctly used the
`gold` tier for priority purposes; only the *metric label* collapsed it).

## Scope note

This is an **observation run**, not one of the 12 numbered Contract 6 scenarios — no
expected-vs-observed verdict against a fault-scenario fixture is computed here (there is no
`fs-NN` for it). It is not counted in `faults/campaign-matrix.md`'s 12 rows. The fairness logic
itself is infergate's; this run observed tier isolation at the ops level and did not tune
anything.
