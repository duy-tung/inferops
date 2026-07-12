# Runbook: Drain

**Evidence base:** IO-T004 (`docs/implementation-notes.md` "2026-07-11 — IO-T004 executed"),
`scripts/drain-test.sh`, `scripts/rolling-update-test.sh`, fault scenario 5,
`deploy/infergate/base/{deployment.yaml,pdb.yaml}`.

## Symptoms / Trigger

A planned removal of one gateway replica — node maintenance, a scale-down, or a single step of a
rolling update — that must not cut in-flight streaming requests.

## Preconditions

- **Replica count ≥ 2** and the PodDisruptionBudget (`deploy/infergate/base/pdb.yaml`,
  `minAvailable: 1`) in place, so draining one replica never drops aggregate capacity to zero.
- **Grace-period arithmetic holds** (recorded, not assumed): `terminationGracePeriodSeconds=50s` >
  `max_stream_duration_seconds=30s` (the gateway's own `-upstream-timeout=30s`) —
  `deploy/infergate/base/deployment.yaml`. If either of these two numbers has drifted since this
  runbook was written, recompute before draining — a grace period shorter than the worst-case
  stream duration will force-kill an accepted, in-flight stream.
- A load balancer (haproxy in this repo's compose topology, a Kubernetes Service in a real
  cluster) health-checking each replica's own `/readyz` so traffic stops routing to a draining
  replica as soon as readiness flips, independent of the drain sequence itself.

## Procedure

1. Ensure baseline is up: `docker compose --profile app up -d gateway` (or confirm the target pod
   is `Ready` in a real cluster).
2. Confirm the replica actually has in-flight work before draining it (optional, for a deliberate
   test — not required for a real operational drain):
   ```
   docker exec <gateway-container> wget -q -O - http://127.0.0.1:8080/metrics | grep '^inference_requests_in_flight'
   ```
3. **Send SIGTERM** to the target replica:
   ```
   docker kill --signal=TERM <gateway-container>
   ```
   Kubernetes equivalent: `kubectl delete pod <name> --grace-period=50` (or a node drain, which the
   kubelet turns into the same SIGTERM-then-grace-period sequence). No `preStop` hook is configured
   for this deployment by design — `cmd/gateway/main.go`'s own SIGTERM handler performs the full
   drain sequence in-process (readiness flips false immediately, new requests get a typed 503,
   accepted streams run to completion within `-drain-timeout`); see the comment in
   `deploy/infergate/base/deployment.yaml` for why a `preStop` hook would contradict, not improve
   on, the deployment-contract descriptor.
4. **During the drain window**, confirm a *new* request against that same replica is refused with a
   typed 503 (readiness flips before the grace period even starts counting down) — do not route new
   traffic to a replica mid-drain via any manual override.
5. **Wait for the container/pod to exit on its own** (never force it) — it should exit well inside
   the 50s grace budget. Only if it does *not* exit on its own within the grace period does the
   orchestrator SIGKILL it — that is the failure mode this runbook exists to avoid observing.

## Verification

- The in-flight stream that was running when SIGTERM was sent completes successfully (HTTP 200,
  terminal `data: [DONE]`) — despite the SIGTERM.
- A new request sent during the drain window gets a typed 503
  (`"Gateway is draining; retry against another replica"`).
- The container/pod exits on its own, well inside the grace budget (no SIGKILL needed).
- This repo's last real run (`scripts/drain-test.sh`, **3/3 passed**,
  `scripts/evidence/drain-test-20260711T234926Z/`): SIGTERM sent 1.04s into a ~2s stream; the
  in-flight stream still returned 200 + terminal `[DONE]`; the concurrent new request got 503; the
  container exited ~1s after the stream finished — far inside the 50s budget.
- Fleet-level confirmation (fault scenario 5, `faults/scenario-05/`): SIGTERM on one of two
  replicas mid-stream, under continuous inferbench load — the terminating replica stopped
  accepting new work and exited cleanly on its own; the other replica kept serving throughout;
  **60/60 requests ok, 0 client-visible errors**.

## Rollback / Escalation

- There is no "rollback" of a drain in the reversible sense — if the replica needs to serve again,
  start a fresh instance of it (same digest) and let the load balancer's health check re-admit it
  once `/readyz` returns 200.
- If a container is SIGKILLed (exceeded the grace period) and an accepted stream was actually cut:
  this is a real incident, not expected behavior. Check whether `-drain-timeout` (gateway flag) is
  misconfigured relative to `terminationGracePeriodSeconds`, or whether an unusually long stream
  (longer than `max_stream_duration_seconds` assumed above) was in flight — recompute the grace-
  period arithmetic. If the arithmetic was correct and the cut still happened, this is a candidate
  gateway defect (drain sequence not honoring its own documented `-drain-timeout`) — file it, don't
  silently extend the grace period as a workaround without understanding why it was needed.
- If drains are happening repeatedly and capacity keeps dropping below what the PDB should protect,
  escalate to `capacity-shortfall.md` — a drain runbook assumes there is spare capacity to drain
  *into*; if there isn't, the underlying problem is capacity, not drain mechanics.

## Walkthrough

**Live-cited.** `scripts/evidence/drain-test-20260711T234926Z/` (3/3 passed) plus fault scenario
5's fleet-level re-confirmation under real inferbench load (`faults/scenario-05/verdict.md`,
60/60 ok, 0 errors) and scenario 12's rolling-update re-confirmation (both replicas drained and
replaced sequentially, 60/60 ok, 0 errors, `faults/scenario-12/verdict.md`) — the same underlying
drain mechanism exercised at three different scales (single forced-overlap test, one fleet member
under load, both fleet members sequentially).
