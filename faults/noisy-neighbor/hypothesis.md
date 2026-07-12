# Noisy neighbor observation run (IO-T007 extra)

- **Goal:** tenant A at 10x load; verify tenant B protection at the ops level (dashboards/metrics
  show tier isolation). The fairness logic itself is infergate's (IG-T011: priority + WRR +
  aging-based admission dispatch, `internal/admission/fairness.go`) — this run observes, it does
  not tune.
- **Setup:** the existing `smoke-tenant` (tier `default` → `DefaultTierPriority` class 1, "low")
  is tenant A; a freshly created `tenant-b-gold` (tier `gold` → class 0, "high",
  `internal/admission/fairness.go:19-27`'s substring match on `"gold"`) is tenant B. Both share
  the one running mock-backend behind the main `-auth-mode=db` gateway (`postgres-dev`-backed, the
  only instance with real per-tenant tiers).
- **Injection:** tenant A fires a large concurrent burst (200 concurrent requests — well above the
  default `admission-global-inflight-budget=128`, forcing real queueing) while tenant B sends a
  light, steady trickle (10 sequential requests) throughout the same window.
- **Expected (ops-level) observation:** tenant B's requests are not starved by tenant A's burst —
  bounded queue wait / success rate for tenant B despite the flood, visible via
  `inference_queue_depth{tenant_tier}` / `inference_queue_wait_seconds{tenant_tier}`'s per-tier
  labels (Contract 2) and this run's own client-side latency record. This is an **observation
  run**, not a numbered Contract 6 scenario — no verdict against a fault-scenario fixture is
  computed; it is reported as a client-side latency/success comparison instead.
