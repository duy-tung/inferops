# Scenario 11 — Readiness during model warm-up

- **Contract reference:** `examples/faults/fs-11-readiness-during-model-warm-up.json` (Contract
  6, item 11): start a fresh engine replica from cold in a pool under traffic; observe the
  rollout until it serves.
- **Already evidenced (IO-T004):** `scripts/warmup-readiness-test.sh` — a delayed-start
  mock-backend (12s injected startup delay, same released digest) against a test-defined
  simulated startupProbe budget (period=2s × failure_threshold=10 = 20s). Original run:
  `scripts/evidence/warmup-readiness-20260711T235223Z/`, 5/5 passed.
- **This campaign's re-confirmation:** re-ran the identical, unmodified script fresh:
  `scripts/evidence/warmup-readiness-20260712T015535Z/` — **5/5 passed again**: `/healthz` failed
  5 times before the backend came up at t=13s (within the 20s simulated budget); a request sent
  at t=3s (mid-warm-up) got a definitive typed 503 (`backend_unavailable`) — never a silent
  success or hang; a request after warm-up succeeded (200); `RestartCount=0` throughout (a startup
  delay, never a crash-restart loop).
- **Expected gateway semantics (verbatim):**
  1. "The replica's readiness is false throughout model load/warm-up ... the gateway routes no
     traffic to it before its warm signal holds."
  2. "The startup-probe budget covers worst-case model load, so liveness never kills a loading
     replica — no restart loops."
  3. "Capacity ramps only when the replica reports warm."
- **Expected client-visible behavior:** "No client-visible errors or latency degradation
  attributable to the cold replica at any point in its warm-up." *(This deployment has exactly one
  backend, so "no errors" cannot literally hold — with zero healthy backends, in-window requests
  get a typed 503, the only honest outcome available; this is the single-replica-pool reduced form
  already recorded at IO-T004, not a new deviation.)*
- **Metrics that must move:** `inference_backend_healthy` stays 0 through warm-up, transitions to
  1 exactly once when warm — confirmed both runs.
- **Metrics that must not move:** `kube_pod_container_status_restarts_total` stays 0 — mapped here
  to the container's own `RestartCount` (Docker's closest analog; no kubelet in this compose
  topology) — confirmed 0 both runs.
- **Client-impact measurement:** not one of the five inferbench-mandated scenarios; the existing
  script's typed-503-not-hang-or-silent-success check is the client-impact record.
