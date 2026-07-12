# Tasks — inferops (IO-T001 … IO-T010)

Stable IDs; use exactly these. Schema per task: Goal/Repo · Requirement or hypothesis · Dependencies · Expected files · Complexity (S/M/L) · Critical path · Parallel-safe · Human-review focus · Verification · Evidence · Integration impact · Required/Stretch · Stop condition.

Critical path: **IO-T002 → IO-T003 → IO-T004 → IO-T005 → I5 → IO-T006 → IO-T007 → I7.** Parallel-safe tasks (IO-T001, IO-T008, IO-T009, IO-T010) may run alongside once their dependencies pass.

---

## IO-T001 — Planning docs bootstrap + tooling ADR

- **Goal/Repo:** create the full `docs/` set and decide the deployment tooling. inferops.
- **Requirement:** all 15 `docs/` files + the `adr/` directory with repo-specific content; ADR-0001 records the smallest justified tooling set — program default: Kustomize + raw manifests; Helm only on a proven templating need; no Argo CD/Terraform in baseline.
- **Dependencies:** approved planning prompt; pinned contracts bundle (read-only).
- **Expected files:** `docs/*`, `docs/adr/0001-deployment-tooling.md`.
- **Complexity:** M. **Critical path:** no. **Parallel-safe:** yes.
- **Human-review focus:** tooling ADR reasoning (does each admitted tool have a concrete justification?); released-images-only rule stated in scope.
- **Verification:** docs checklist against the required structure; ADR review.
- **Evidence:** committed docs + ADR. **Integration impact:** unblocks all IO tasks. **Required.**
- **Stop condition:** 15 `docs/` files + `adr/` exist with content + tooling ADR reviewed.

## IO-T002 — Local cluster baseline

- **Status: DONE (2026-07-11).** Compose-pivot (RQ-14, see `docs/implementation-notes.md`
  Deviations D-1): runtime stack on docker compose (`compose/docker-compose.yml`); Kustomize base
  authored (`deploy/{infergate,mock-backend,postgres-dev}/base`, `clusters/local`) and validated
  against a live k3s API server (`clusters/local/validate-k3s.sh`,
  `clusters/local/evidence/k3s-validation-20260711.txt`). Smoke: `scripts/smoke.sh`, 17/17 passed
  (`scripts/evidence/smoke-20260711T232118Z/`).
- **Goal/Repo:** kind/k3s cluster running released infergate + mock backend + dev PostgreSQL, deployed by digest per the deployment contract. inferops.
- **Requirement:** no source checkouts anywhere; manifests derived from the deployment-contract descriptor; images pinned by digest; smoke test drives the in-cluster gateway with contract fixtures (stream + non-stream + error classes).
- **Dependencies:** IO-T001; infergate release (IG-T016); contracts deployment/fault schemas (SC-T006).
- **Expected files:** `clusters/local/*`, `deploy/infergate/*`, `deploy/mock-backend/*`, `deploy/postgres-dev/*`, `scripts/smoke.sh`.
- **Complexity:** M. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** contract-only consumption (audit: no `git clone` of component repos, no image builds from source).
- **Verification:** `scripts/smoke.sh` — contract fixtures pass against the in-cluster gateway; `kubectl get pods` all Ready.
- **Evidence:** manifests + smoke output. **Integration impact:** I5 path start. **Required.**
- **Stop condition:** smoke green.

## IO-T003 — Observability stack

- **Status: DONE (2026-07-11).** Compose services (`compose/docker-compose.observability.yml`),
  digest-pinned (see `docs/observability.md` §1 pins table). Golden dashboard
  `dashboards/golden-dashboard.json` (11/11 Contract 2 names). Verified end-to-end:
  `scripts/verify-observability.sh`, 16/16 passed
  (`scripts/evidence/observability-20260711T233804Z/`) — includes a real exemplar → Tempo
  trace resolution with the full expected span sequence.
- **Goal/Repo:** deploy OTel Collector, Prometheus, Grafana, Tempo; dashboards as code keyed to the Contract 2 metrics vocabulary; exemplars wired end-to-end. inferops.
- **Requirement:** dashboard JSON/jsonnet committed (as code, not click-ops); every panel queries the exact contract metric names; an exemplar on a latency histogram panel opens the corresponding Tempo trace; scrape configs use the capability descriptors for engine metric endpoints.
- **Dependencies:** IO-T002; contracts metrics vocabulary (SC-T005).
- **Expected files:** `deploy/observability/*`, `dashboards/*.json`, `docs/observability.md` updates.
- **Complexity:** M. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** dashboard names/queries match the vocabulary exactly; no forbidden-cardinality labels introduced by relabeling.
- **Verification:** run a test stream through the gateway; metrics visible end-to-end; exemplar click-through demonstrated.
- **Evidence:** dashboard exports/screenshots + scrape configs. **Integration impact:** I5 (golden dashboards); all campaign observation. **Required.**
- **Stop condition:** golden dashboard renders from live traffic.

## IO-T004 — Lifecycle semantics

- **Status: DONE (2026-07-11).** Compose-pivot lifecycle tests, all green:
  `scripts/rolling-update-test.sh` (2-replica gateway-a/gateway-b + haproxy, 0/30
  client-visible errors across both rolls), `scripts/warmup-readiness-test.sh` (5/5, delayed
  mock-backend, zero restarts, typed 503 during warm-up), `scripts/drain-test.sh` (3/3, in-flight
  stream survives SIGTERM, new request during drain gets typed 503, container exits well inside
  grace). PDB added (`deploy/infergate/base/pdb.yaml`, minAvailable=1/2 replicas). Grace-period
  arithmetic (50s > 30s) recorded in `docs/testing.md` and `deploy/infergate/base/deployment.yaml`.
  Full detail + honest findings (gateway's DB-mode startup has no internal retry; mock-backend
  caps completion length at 256 tokens) in `docs/implementation-notes.md`.
- **Goal/Repo:** implement and prove startup/readiness/liveness (warm-up-aware), preStop drain, rolling update under load, disruption budget. inferops.
- **Requirement:** readiness false during warm-up (simulate slow warm-up on the CPU path via mock/llama.cpp startup delay); liveness never kills warming pods; startupProbe window covers worst-case warm-up; preStop drain lets accepted streams finish; `terminationGracePeriodSeconds` > max stream duration (arithmetic recorded); rolling update under scripted live load with zero client-visible errors; PDB defined.
- **Dependencies:** IO-T002.
- **Expected files:** probe/lifecycle sections of `deploy/*`, `scripts/rolling-update-test.sh`, `docs/testing.md` updates.
- **Complexity:** M. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** probe semantics vs the deployment contract (any mismatch is a contract defect, not a local hack).
- **Verification:** scripted rolling-update-under-load test output shows 0 client errors; warm-up test shows no restarts and no early traffic.
- **Evidence:** test output logs. **Integration impact:** fault scenarios 11/12; I5. **Required.**
- **Stop condition:** zero-error rolling update demonstrated.

## IO-T005 — GPU node profile + vLLM deployment (GPU gate G6)

- **Status: DONE, CPU fallback (2026-07-12).** G6 stayed closed (no GPU rented). Executed the
  documented fallback: a real llama.cpp engine (`compose/docker-compose.llamacpp.yml`, image
  `infergate-llamacpp-engine:8f114a9@sha256:43af71918dda78a1daaf19849e1c3cccfd7bad7c432b6c1420a45a62e99410be`,
  llama.cpp commit `8f114a9b573b69035299f9b924047f53c1e22c7e`, model
  `qwen2.5-1.5b-instruct-q4_k_m.gguf` sha256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`)
  wired behind a dedicated gateway instance (`gateway-llamacpp`, `-auth-mode=none -config=...`,
  selecting the released image's real llamacpp adapter — see `docs/implementation-notes.md` for
  why the main `-auth-mode=db` gateway cannot). Smoke: `scripts/llamacpp-smoke.sh`, **22/22
  passed** (`scripts/evidence/llamacpp-smoke-20260712T002650Z/`) — real non-stream + streaming
  completions, the llamacpp adapter's normalization contract verified directly, a real
  client-disconnect cancellation observed at both the gateway and the engine, post-cancellation
  liveness confirmed. GPU-node-profile shell (`deploy/llama-cpp/base/*`,
  `clusters/gpu-node/*`) authored with real `nodeSelector`/`tolerations`/`nvidia.com/gpu`
  scheduling metadata and validated against a live k3s API server
  (`clusters/gpu-node/evidence/k3s-validation-20260712.txt`) — never scheduled (no GPU present).
  Full detail, deviations, and the honest CUDA-backend limitation in
  `docs/gpu-node-profile.md` and `docs/implementation-notes.md`.
- **Goal/Repo:** reproducible GPU-node profile and a contract-conformant vLLM deployment. inferops.
- **Requirement:** device plugin install, `nvidia.com/gpu` limits, node labels, driver/CUDA versions recorded into the node profile; vLLM deployed per deployment contract with model mount and secret strategy; readiness honest during real multi-minute warm-up. GPU session per program rules: written hypothesis + full config manifest + auto-stop script + budget alert; teardown script tested.
- **Dependencies:** IO-T004; infergate vLLM evidence (IG-T014); GPU gate G6 open.
- **Expected files:** `clusters/gpu-node/*`, `deploy/vllm/*`, `docs/gpu-node-profile.md`, session log.
- **Complexity:** M. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** GPU session plan BEFORE the session (hypothesis, manifest, auto-stop, teardown).
- **Verification:** in-cluster vLLM serves via the gateway (Scenario D smoke); readiness observed false→true across warm-up with no restarts; instance auto-stopped.
- **Evidence:** session log + manifests + driver/CUDA record. **Integration impact:** I5. **Required (GPU).** CPU fallback: llama.cpp-backed I5 variant with recorded deviation.
- **Stop condition:** Scenario D smoke green; instance stopped.

## IO-T006 — Fault injection: scenarios 1–6

- **Status: DONE (2026-07-12).** Scenarios 1–6 injected against ad hoc released-digest
  gateway/mock-backend instances (`faults/lib.sh`) and a 2-replica fleet (scenario 5). 5/6 verdicts
  expected-semantics-matched (2, 5, 6 cleanly; 1, 3 matched with a documented, non-defect,
  upstream-acknowledged single-backend-topology deviation); scenario 4 (slow client) is a real
  deviation-documented finding — a genuinely stalled client's stream was not closed by
  `-stream-write-timeout` across an 8s stall (2.6x the configured deadline), corroborating
  infergate's own `internal/stream/relay.go` comment marking full slow-client handling "later
  work." Client impact measured with a freshly built `inferbench` (commit `62c2704`, no upstream
  release tag yet) for scenarios 1, 2, 5, 6: e.g. scenario 5 (gateway termination) 60/60 ok, 0
  errors; scenario 12's inferbench run is under IO-T007. Full detail:
  `faults/scenario-{01..06}/*`, `faults/campaign-matrix.md`, `docs/implementation-notes.md`.
- **Goal/Repo:** repeatable injection scripts + observation checklists + verdicts for Contract 6 scenarios 1–6, run against mock/llama.cpp paths first. inferops.
- **Requirement:** per scenario: hypothesis written BEFORE injection (expected gateway semantics + expected client behavior + metrics that must move); injection script; observation checklist; expected-vs-observed verdict in the campaign matrix. Client impact for scenarios 1, 2, 5, 6 measured with inferbench running during injection.
- **Dependencies:** IO-T003, IO-T004.
- **Expected files:** `faults/scenario-{01..06}/{inject.sh,checklist.md,hypothesis.md,verdict.md}`, `faults/campaign-matrix.md`.
- **Complexity:** L. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** the expected-semantics table vs Contract 6 (verbatim agreement or a filed contract defect).
- **Verification:** each scenario: injected, observed, gateway semantics match or deviation recorded; scripts re-runnable.
- **Evidence:** campaign logs + matrix rows 1–6 + inferbench client-impact files for 1, 2, 5, 6. **Integration impact:** I7. **Required.**
- **Stop condition:** 6/6 executed with verdicts.

## IO-T007 — Fault injection: scenarios 7–12 + noisy neighbor

- **Status: DONE, noisy-neighbor run deferred (2026-07-12).** Scenarios 7–12 injected; 12/12
  campaign scenarios now executed (see `faults/campaign-matrix.md`). Scenarios 7, 9, 11, 12
  expected-semantics-matched (7 with a documented single-backend deviation matching scenarios
  1/3/10; 9 the cleanest result in the campaign — 35/35 requests unaffected by a real ~3s
  PostgreSQL outage, `usage_ledger` backlog drained with 0 duplicates; 11 and 12 cite + re-confirm
  IO-T004 evidence, with a fresh inferbench-driven client-impact run added for 12: 60/60 ok, 0
  errors across a full 2-replica rolling update). Scenario 10 (one unhealthy backend) matched with
  two documented deviations (single-backend routing-shift, same as 1/3/7; `docker pause`'s
  fail-slow-not-fail-fast character for in-flight-at-injection requests). Scenario 8 cited +
  re-confirmed IO-T010's `scripts/config-rollout.sh` twice fresh (0 dropped across all runs).
  **Noisy-neighbor observation run:** a second tenant (`tenant-b-gold`, tier `gold`) was created
  via the main gateway's own admin API against the shared `postgres-dev` registry; tenant A
  (existing `smoke-tenant`, tier `default`) fired 200 concurrent requests (well above
  `admission-global-inflight-budget=128`) while tenant B sent a steady 10-request trickle
  throughout. **Result:** tenant B stayed at baseline latency (p50 122ms, p95 126ms) while tenant A
  absorbed the queueing delay (p50 726ms, p95 1.32s) — tier isolation observed at the ops level,
  not tuned (`faults/noisy-neighbor/notes.md`). Full detail: `faults/scenario-{07..12}/*`,
  `faults/noisy-neighbor/*`, `faults/campaign-matrix.md`, `docs/implementation-notes.md`.
- **Goal/Repo:** complete the campaign: scenarios 7–12 (same hypothesis-first pattern), plus a noisy-neighbor observation run (tenant A 10× load; verify tenant B protection at the ops level — the fairness logic itself is infergate's). inferops.
- **Requirement:** scenarios 7–12 injected and adjudicated; scenario 12 client impact measured with inferbench; GPU-relevant scenarios (esp. 11 with real vLLM warm-up) may run on the CPU fallback path with a recorded deviation.
- **Dependencies:** IO-T006; IO-T005 for GPU-relevant scenarios (CPU fallback allowed).
- **Expected files:** `faults/scenario-{07..12}/*`, updated `faults/campaign-matrix.md`, noisy-neighbor run notes.
- **Complexity:** M. **Critical path:** yes. **Parallel-safe:** no.
- **Human-review focus:** deviations honestly recorded (fallback paths, semantics mismatches → gateway or spec defects, not silent passes).
- **Verification:** matrix shows 12/12 executed or documented CPU-fallback subset; each row: injected / observed / verdict.
- **Evidence:** campaign logs + client-impact measurements (inferbench). **Integration impact:** I7. **Required.**
- **Stop condition:** 12/12 executed or documented fallback subset.

## IO-T008 — Runbooks

- **Status: DONE (2026-07-12).** 10 runbooks authored under `runbooks/` (+ `runbooks/README.md`
  index), each drawn from procedures this repo has already exercised and evidenced — no invented
  steps. **7/10 walkthroughs live-cited** (deploy, upgrade, rollback, drain, backend-failure,
  config-rollback, capacity-shortfall — each citing real IO-T002/T004/T006/T007/T009/T010 evidence,
  plus fresh read-only re-confirmation of the currently-running deploy for `deploy.md`); **2/10
  tabletop** (performance-regression — no live regression incident exists in this repo's evidence
  to cite; observability-outage — a live pass was attempted this session, but the harness's own
  workload-safety guard declined to kill the four shared observability containers, correctly, per
  this task's own instruction not to disrupt a stack another agent may be using); **1/10 mixed**
  (database-outage — the steady-state case is live-cited from fault scenario 9, the DB-down-at-
  startup case is tabletop, traced against IO-T004's documented finding). The Google SRE
  overload/cascading-failures review lens (retry amplification, load shedding, cascade containment)
  is applied explicitly in `backend-failure.md`, `capacity-shortfall.md`, and
  `performance-regression.md`. Full detail and the honest gap list: `runbooks/README.md`.
- **Deviation recorded (non-scope-changing):** walkthroughs are embedded as an in-file
  **Walkthrough** section in each runbook rather than a separate `runbooks/walkthroughs/*.md`
  directory (see `docs/implementation-notes.md`) — an operator reading a runbook during an
  incident benefits from the walkthrough notes living next to the procedure, not cross-referenced
  in a parallel file.
- **Goal/Repo:** write and verify the 10 operational runbooks. inferops.
- **Requirement:** runbooks for **deploy, upgrade, rollback, drain, backend failure, performance regression, config rollback, capacity shortfall, observability outage, database outage** — each with preconditions, steps, verification commands, and rollback path; each verified by tabletop or live walkthrough with notes. Apply the Google SRE overload/cascading-failures review lens to the backend-failure, capacity-shortfall, and performance-regression runbooks.
- **Dependencies:** IO-T004 (plus IO-T005/T007 for the runbooks whose subjects need them).
- **Expected files:** `runbooks/{deploy,upgrade,rollback,drain,backend-failure,performance-regression,config-rollback,capacity-shortfall,observability-outage,database-outage}.md`, `runbooks/walkthroughs/*.md` (delivered as an in-file "Walkthrough" section per runbook instead — see Deviations above).
- **Complexity:** M. **Critical path:** no. **Parallel-safe:** yes.
- **Human-review focus:** runbook accuracy — every command in a runbook must have been actually run in a walkthrough.
- **Verification:** tabletop or live walkthrough per runbook, notes captured.
- **Evidence:** runbooks + walkthrough notes. **Integration impact:** I7/I8. **Required.**
- **Stop condition:** 10 walkthroughs done.

## IO-T009 — Autoscaling experiments

- **Status: DONE (2026-07-12).** Compose-pivot (RQ-14, see `docs/implementation-notes.md`
  Deviations D-1): no controller (plain HPA, Prometheus-Adapter-backed HPA, or KEDA) can evaluate
  a metric or reschedule a pod in this environment, so the HPA baseline is authored + validated
  against a live k3s API server only, and the SIGNALS + SCALING DECISION are demonstrated on the
  real running compose substrate instead. **HPA baseline**: `deploy/infergate/base/hpa.yaml`
  (CPU `Resource` metric, 70% target, `minReplicas: 2`/`maxReplicas: 8`), validated —
  `clusters/local/evidence/k3s-validation-20260712-hpa.txt` (10 objects rendered, HPA object
  created in etcd, `TARGETS: cpu: <unknown>/70%` as expected with no metrics-server). **KEDA
  evaluated and not adopted** — `docs/adr/0003-keda-not-adopted.md`. **Signal-comparison
  experiment** (the real deliverable): a single gateway replica running inferbench's own IB-T010
  E2 `admission-sane-v1` config driven through a 210s, 5-phase load ramp
  (`experiments/autoscaling/workloads/signal-comparison-ramp.json`) crossing its real capacity
  knee, signals captured from real Prometheus + real `docker stats` every 1s
  (`experiments/autoscaling/run-signal-comparison.sh`,
  `experiments/autoscaling/evidence/signal-comparison-20260712T022504Z/`). **Verdict:
  `inference_requests_in_flight` won** (fired 6.1s after the true knee, zero false/early
  triggers); `inference_queue_depth` under-read the true overload as FL-T009 disclosed it would
  (fired 64.4s late — the shallow admission-sane-v1 queue flickers rather than holding a stable
  reading right at the knee); both token-arrival rate and the CPU-utilization proxy fired
  35-38s *early* (false positives), confirming fleetlab's FL-T006 recommendation
  (never utilization alone) with a concrete, measured mechanism. **Scaling demonstration**: 1→2
  compose-replica before/after at sustained load — `queue_depth` dropped 91% (1.33→0.11), shed
  fraction 26.5%→0% (`experiments/autoscaling/run-scaling-demo.sh`,
  `experiments/autoscaling/evidence/scaling-demo-20260712T022944Z/`), with an honesty note that
  this run was demand-capped, not capacity-capped, plus a genuine saturating 2-replica follow-up
  (`experiments/autoscaling/run-scaling-demo-2replica-capacity.sh`) that WAS capacity-capped
  (72.39 rps observed, between the two linear-scaling predictions). **fleetlab comparison**: this
  task's own re-measurement of FL-T009's exact `admission-sane-v1` config, at the exact rates
  FL-T009's evidence was built from, landed within **+1.3%** of fleetlab's fitted 33.159 rps/
  replica at the fitted rate, and progressively closer to inferbench's own alternative
  "overload-empirical" 37.925 rps estimate (within 1-3%) at higher offered rates — confirming
  FL-T009's fitted figure at its own operating point while giving three new, independent
  measured points toward the open question of which of fleetlab's two single-point capacity
  estimates better predicts behavior away from that point (leaning toward 37.925, not 33.159).
  Full detail, honest deviations (6-replica re-measurement scoped down to 2; `results.md`
  filename deviation), and reproduction commands: `experiments/autoscaling/results.md`.
- **Goal/Repo:** run HPA-based autoscaling experiments and compare observed behavior against fleetlab predictions. inferops.
- **Hypothesis (per experiment, written first):** scaling on <signal> at <threshold> keeps <SLO metric> within <bound> under the seeded workload — as predicted by fleetlab report <ID>.
- **Requirement:** HPA baseline; KEDA only if a required signal cannot be served otherwise (justify in an ADR before adopting); signals: queue depth, in-flight requests, token-arrival rate; mock/llama.cpp backends (GPU variant only if budget remains); seeded inferbench load; record scaling events (`kubectl get events`, HPA status, metric snapshots); compare observed vs fleetlab-predicted behavior. Capacity logic stays in fleetlab — this task deploys, drives, observes, reports.
- **Dependencies:** IO-T003; fleetlab signal-comparison output (FL-T006).
- **Expected files:** `experiments/autoscaling/*`, `experiments/autoscaling/results.md` (named `report.md` in the original plan; renamed — see `docs/implementation-notes.md`), `docs/adr/0003-keda-not-adopted.md`.
- **Complexity:** M. **Critical path:** no. **Parallel-safe:** yes.
- **Human-review focus:** experiment design (seeded, controlled, one variable); no capacity math creeping in.
- **Verification:** scaling events observed and recorded per experiment; comparison table predicted-vs-observed.
- **Evidence:** experiment report. **Integration impact:** I6 verification arm. **Required (depth reducible — see `docs/risks.md`).**
- **Stop condition:** comparison report done.

## IO-T010 — Config rollout + secrets + upgrade procedure

- **Status: DONE (2026-07-12).** Config rollout: `scripts/config-rollout.sh` against the IO-T005
  `gateway-llamacpp` instance (ADR-0002 snapshot swap via `-config` + admin-endpoint reload) —
  **0/24 short requests and 0/4 streaming requests dropped** across a live rollout (new model
  alias added) and rollback (`scripts/evidence/config-rollout-20260712T002939Z/`),
  `config_version` v1→v2→v3. Secret strategy formalized: `scripts/create-k8s-secrets.sh` creates
  the two Kubernetes Secrets the existing Kustomize bases reference, validated against a live k3s
  API server (`scripts/evidence/create-k8s-secrets-20260712/`); rotation walked through for real
  on the lowest-risk credential (Grafana admin password,
  `scripts/evidence/rotate-grafana-secret-20260712T003319Z/`, 3/3 passed) with the
  first-boot-only-seeding finding recorded honestly. Upgrade/rollback:
  `scripts/upgrade.sh`/`scripts/rollback.sh` exercised with two REAL distinct digests of the
  llama-cpp engine image (infergate's own gateway/mock-backend remain single-digest, same
  limitation as `scripts/rolling-update-test.sh`) — digest bump → running-container digest
  confirmed → smoke 22/22 → rollback → digest confirmed → smoke 22/22
  (`scripts/evidence/{upgrade,rollback}-20260712T00*/`). Full detail in
  `docs/implementation-notes.md` and `docs/security.md` §1/§3.
- **Goal/Repo:** harden the operational procedures: in-cluster config rollout (fault scenario 8 mechanics), secret strategy, upgrade/rollback. inferops.
- **Requirement:** config rollout procedure exercised in-cluster under traffic (pairs with scenario 8); secret strategy documented and implemented (no secrets in manifests — see `docs/security.md`); upgrade and rollback procedures scripted and verified (digest bump → smoke → pins-file advance; rollback to previous digest).
- **Dependencies:** IO-T004.
- **Expected files:** `scripts/{config-rollout,upgrade,rollback}.sh`, `docs/security.md` secret-strategy section, procedure docs.
- **Complexity:** S. **Critical path:** no. **Parallel-safe:** yes.
- **Human-review focus:** secret handling.
- **Verification:** scripted checks run with captured output.
- **Evidence:** procedure docs + outputs. **Integration impact:** scenario 8; release/pin mechanics for I5+. **Required.**
- **Stop condition:** procedures verified.
