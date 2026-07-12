# Runbook: Capacity Shortfall

**Evidence base:** IO-T009 (`experiments/autoscaling/run-scaling-demo.sh`,
`run-scaling-demo-2replica-capacity.sh`, `run-signal-comparison.sh`, `results.md`),
`deploy/infergate/base/hpa.yaml`, `docs/adr/0003-keda-not-adopted.md`, fleetlab Contract 7
recommendation numbers cited in `experiments/autoscaling/results.md` §4.

**SRE overload/cascading-failures lens applied** per `docs/tasks.md` IO-T008 /
`docs/experiments.md` §4.

## Symptoms / Trigger

- `inference_sheds_total` rising on the golden dashboard.
- `inference_requests_in_flight` and/or `inference_queue_depth` sustained near the admission caps.
- Goodput (achieved rps) plateauing below offered load.
- The "Queue-depth sustained growth" alert sketch (`docs/observability.md` §7) fires.

## Preconditions

- Understand which signal to trust for detection **before** reacting — see Diagnosis step 2. Using
  the wrong signal either triggers scale-out far too late or triggers on noise.
- Know the current replica topology and the PDB (`minAvailable: 1`) so scale-out doesn't violate
  disruption assumptions elsewhere.
- **No live autoscaling controller evaluates anything in this sandbox** (RQ-14 —
  `docs/implementation-notes.md` Deviations D-1): `deploy/infergate/base/hpa.yaml` is authored and
  validated against a live k3s API server only (`TARGETS: cpu: <unknown>/70%`, no metrics-server
  running) — it has never triggered a real scale event here. **Scale-out is a manual operator
  action in this environment**, not automatic. On a real cluster where a controller can actually
  evaluate metrics, this gap closes; until then, whoever is on call must know scaling will not
  happen by itself.

## Diagnosis

1. Check the golden dashboard's shed-by-reason and queue-depth/in-flight panels.
2. **Use `inference_requests_in_flight` as the primary detection signal for a shallow-queue
   admission profile**, not `inference_queue_depth` alone. IO-T009's measured comparison
   (`experiments/autoscaling/results.md` §2.2): `in_flight` fired 6.1s after the true capacity
   knee with zero false/early triggers; `queue_depth` under-read the same overload, firing 64.4s
   *late* — deep into severe overload — because a shallow queue (cap 3, 500ms deadline) flickers
   near 0 right at the knee rather than holding a stable elevated reading. **A flat `queue_depth`
   reading does not mean "no shortfall."**
3. Never use token-arrival rate or CPU utilization as the primary trigger — both fired 34-38s
   *early* (false positives) in the same measured comparison.
4. Confirm the shortfall is real overload, not a downstream single-backend ceiling (see
   `backend-failure.md`'s single-backend-topology note) — scaling gateway replicas does not add
   backend/engine capacity if the backend itself is the bottleneck.

## Mitigation — manual scale-out (this environment)

Compose (this repo's actual runtime, per RQ-14):
1. Bring up an additional gateway + backend replica pair on the same released digests:
   ```
   docker run -d --name <new-gateway> --network inferops-net --network-alias <alias> \
     <gateway-image>@<digest> -addr=:8080 ...
   docker run -d --name <new-backend> --network inferops-net --network-alias <backend-alias> \
     <backend-image>@<digest> ...
   ```
   (Exact flag set: mirror `experiments/autoscaling/run-scaling-demo.sh`'s `start_mock`/
   `start_gateway` pattern in `faults/lib.sh`.)
2. Add the new replica to the load balancer's backend list and reload/restart it:
   `experiments/autoscaling/haproxy-signals.cfg` — this repo's evidence used a fresh haproxy
   container with both targets already configured (not a live haproxy runtime-API reload);
   recorded honestly as the actual mechanism exercised, not a hot-reload of a running haproxy.
3. Confirm the new target is healthy in the load balancer and in Prometheus's scrape target list
   before expecting it to absorb load.

Kubernetes (the real target once RQ-14 lifts, or on a normal cluster):
```
kubectl scale deployment/infergate-gateway --replicas=<n>   # up to hpa.yaml's maxReplicas: 8
kubectl rollout status deployment/infergate-gateway
```
Respect the PDB (`minAvailable: 1`) throughout — this is naturally satisfied by scaling up, only a
concern when scaling back down.

## Verification

- `queue_depth`/`in_flight` trend downward after the new replica joins.
- Shed rate drops toward 0 — this repo's measured example: `queue_depth` dropped **91%** (1.33 →
  0.11 mean) and shed fraction dropped **26.48% → 0.00%** within 3s of the second replica joining
  (`experiments/autoscaling/evidence/scaling-demo-20260712T022944Z/`).
- **Confirm the AFTER state is genuinely capacity-recovered, not just demand-below-the-new-ceiling.**
  A 0% shed rate after scaling can mean either "the shortfall is resolved" or "offered load never
  reached the new ceiling" — check that goodput is actually tracking offered rate, not just that
  shedding stopped. This repo's own evidence caught exactly this distinction: an initial AFTER run
  at 50 rps showed 0% shed but was **demand-capped, not capacity-capped** (50 rps never reached the
  real 2-replica ceiling); a follow-up run at 80 rps (comfortably above 2× either single-replica
  capacity estimate) was genuinely capacity-capped, observing **72.39 rps** goodput with **8.81%**
  shed even after scale-out — i.e. scale-out reduces but does not always eliminate shedding if
  offered load still exceeds the new capacity.

## SRE overload/cascading-failures lens

- **A capacity shortfall that is shedding correctly (typed 503 + `Retry-After`, admitted-request
  latency protected) is a controlled degradation** — confirm this before treating it as an
  emergency on par with an untyped/hung failure.
- **Watch for retry amplification converting a shortfall into a self-inflicted retry storm.** The
  gateway respects `Retry-After` discipline on its own shed responses; if client fleets ignore it
  and hammer harder, a capacity shortfall becomes a retry storm (the exact mechanism fault scenario
  7 measured: retries stay bounded to the gateway's own budget ratio regardless of client
  aggression, but that budget applies to the gateway's *own* retries, not to how hard an impatient
  client fleet re-sends). Coordinate with client owners on `Retry-After` compliance rather than
  just adding capacity to try to outrun an amplifying client-side loop.
- **Scale-out timing depends on using the right signal** (Diagnosis step 2) — an operator using
  `queue_depth` alone for a shallow-queue config scales 64s too late; an operator using CPU
  utilization scales 35-38s too eagerly on noise. Getting this wrong in either direction either
  prolongs shedding or wastes capacity reactively.
- **Capacity math (how many replicas, at what predicted goodput) belongs to fleetlab's Contract 7
  recommendation — apply it, never invent an ad hoc threshold mid-incident.** `docs/scope.md`'s
  boundary is explicit: inferops deploys, drives, and observes; it does not compute what capacity
  *should* be.

## Escalation

- If scale-out does not relieve the shortfall, check whether the actual bottleneck is downstream
  of the gateway (a single shared backend/engine — see `backend-failure.md`'s single-backend-
  topology constraint). Scaling gateway replicas alone adds no backend capacity.
- If the shortfall recurs at a load level well below what the last fleetlab recommendation
  predicted the deployed topology should absorb, that recommendation is stale — request a fresh
  Contract 7 recommendation rather than hand-tuning admission caps as a substitute for real
  capacity planning.

## Walkthrough

**Live-cited.** `experiments/autoscaling/evidence/scaling-demo-20260712T022944Z/`: 1-replica
BEFORE vs. 2-replica AFTER at an identical seeded 50 rps sustained load — `queue_depth` dropped 91%
(1.33 → 0.11), shed fraction dropped 26.48% → 0.00%, 3s measured scale-out wall time (haproxy
fronting both replicas). Follow-up genuinely-capacity-capped check
(`experiments/autoscaling/evidence/scaling-demo-2replica-capacity-20260712T023333Z/`, 80 rps
against 2 replicas from the start): 72.39 rps observed goodput, 8.81% shed — confirming scale-out
helps but does not eliminate shedding once offered load exceeds the new ceiling, the honest nuance
this runbook's Verification section states explicitly.
