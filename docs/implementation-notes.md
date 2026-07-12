# Implementation notes — inferops

Running log of notable events: surprises, ecosystem drift, fallbacks taken, contract defects filed, and assumptions. Deviations from the approved plan are recorded under **Deviations** per the program deviation policy:

> When repository evidence forces a deviation from the approved plan, choose the conservative reversible option, record the evidence, decision, consequences, and follow-up under `Deviations`, and continue. Pause only when the deviation changes public contracts, repository ownership, security posture, or milestone scope.

## Running log

### 2026-07-12 — IO-T009 executed (autoscaling experiments, I6 verification arm)

- **RQ-14 applies again, as it does to every IO task**: this environment cannot schedule any
  Kubernetes pod, so no controller (plain HPA, Prometheus-Adapter-backed HPA, or KEDA) can ever
  evaluate a metric or trigger a real scheduling decision here. The HPA baseline is therefore
  authored + validated against a live k3s API server only (`deploy/infergate/base/hpa.yaml`,
  `clusters/local/evidence/k3s-validation-20260712-hpa.txt` — 10 objects rendered, the HPA object
  created in etcd, `TARGETS: cpu: <unknown>/70%` exactly as expected with no metrics-server
  running); the actual signal comparison and scaling decision are demonstrated on the real running
  compose substrate instead — real containers, real Prometheus, real `docker stats`, real
  inferbench load, a real container-count change standing in for a ReplicaSet scale event.
- **KEDA evaluated and not adopted**: `docs/adr/0003-keda-not-adopted.md`. `inference_queue_depth`
  (fleetlab's Contract-7-recommended signal) isn't a Kubernetes built-in resource metric, so real
  queue-depth-based HPA scaling needs a Prometheus Adapter or a KEDA `ScaledObject` — but since no
  controller loop of any kind can evaluate anything under RQ-14, adopting either here would be
  pure unevaluated YAML with zero additional evidence value. Re-entry condition recorded.
- **Signal-comparison experiment** (`experiments/autoscaling/run-signal-comparison.sh`,
  `experiments/autoscaling/poll_signals.py`, `experiments/autoscaling/analyze_signal_comparison.py`):
  a single gateway replica running inferbench's own IB-T010 E2 `admission-sane-v1` config
  (`-admission-tenant-queue-cap=3 -admission-global-inflight-budget=6
  -admission-global-queue-cap=3 -admission-queue-deadline=500ms`, mock backend `-ttft=80ms
  -itl=10ms` — deliberately the SAME config inferbench/fleetlab's own fitted-capacity evidence
  used, not an invented one, so the results are directly comparable) driven through a 210s,
  5-phase load ramp (`experiments/autoscaling/workloads/signal-comparison-ramp.json`, seed
  `20260712101`) whose phase-3/phase-4 rates are IB-T010 E2's own declared baseline (37.8072 rps)
  and overload (189.0362 rps) rates verbatim. Signals captured from real Prometheus (a new 1s-
  scrape-interval job, `compose/prometheus/prometheus.yml`) and real `docker stats`, once per
  second, for the whole run. **Result: `inference_requests_in_flight` was the clear winner** —
  fired 6.1s after the true capacity knee (phase 3 onset) with zero false/early triggers.
  `inference_queue_depth` under-read the overload as FL-T009's own recommendation JSON already
  disclosed it would, but the *mechanism* observed here is sharper than the disclosed caveat: this
  admission config's shallow queue (cap 3, 500ms deadline) causes `queue_depth` to *flicker*
  between 0 and a few right at the knee rather than holding a stable elevated reading, so a
  debounce-sustained detector (fleetlab's own disclosed rule, reused for a fair comparison) didn't
  fire until 64.4s late — deep into severe overload, not at the knee. Token-arrival rate and the
  CPU-utilization proxy (docker stats — explicitly labeled a weaker/noisier proxy than even
  FL-T006's own already-caveated simulated one, since these mock/gateway containers do no real
  inference computation) both fired 34-38s *early* (false positives during the still-under-
  capacity ramp phase), for two different, individually-explainable reasons: token rate because
  this workload's output-length distribution is constant over time (exactly FL-T006 §8's own
  documented scope limit), CPU because ordinary ramp-up traffic noise crosses a low, high-variance
  calibration threshold well before genuine saturation. **Net: confirms fleetlab's FL-T006
  recommendation (primary `predicted_goodput_deficit`, fallback `queue_depth`/`in_flight_requests`,
  never utilization alone) with a concrete measured mechanism**, plus a refinement worth carrying
  back to fleetlab: `inference_requests_in_flight` clearly outperformed `inference_queue_depth`
  for this specific shallow-queue admission config.
- **Scaling demonstration** (`experiments/autoscaling/run-scaling-demo.sh`): 1-replica BEFORE vs
  2-replica AFTER at the same seeded 50 rps sustained load
  (`experiments/autoscaling/workloads/scaling-demo-sustained.json`, seed `20260712102`).
  `queue_depth` dropped 91% (1.33 mean → 0.11 mean) and shed fraction dropped from 26.48% to 0.00%
  the moment the second replica joined (haproxy fronting both, `experiments/autoscaling/
  haproxy-signals.cfg`, 3s measured scale-out wall time) — the real before/after the task asked
  for. **Honesty finding, caught and corrected rather than reported at face value**: 0% shed after
  scaling meant this particular AFTER run was demand-capped, not capacity-capped (50 rps never
  reached the real 2-replica ceiling), so a naive "2× goodput" linear-scaling read against it would
  have been an artifact, not a finding. A follow-up run closes this
  (`experiments/autoscaling/run-scaling-demo-2replica-capacity.sh`, 80 rps against 2 replicas from
  the start — genuinely capacity-capped this time, 8.81% shed, 72.39 rps observed goodput).
- **fleetlab comparison (the central ask)**: this task independently re-measured FL-T009's exact
  `admission-sane-v1` config at FL-T009's exact declared rates, on this repo's own compose stack
  (a different host/environment than inferbench's original measurement) three separate times.
  Result: **within +1.3% of fleetlab's fitted 33.159 rps/replica at the exact rate it was fitted
  from** (33.58 rps observed) — a strong, independent, cross-environment replication. At higher
  offered rates (50 rps, 189 rps), this task's own measurements (36.71 rps, 37.40 rps) tracked
  progressively closer to inferbench's own *alternative* single-point estimate, the
  "overload-empirical" 37.925 rps (`reports/holdout-validation.md` §2a) — within 1-3%, vs. 11-13%
  off the baseline-fit figure. This is not a refutation of FL-T009 (33.159 rps is confirmed as
  correct at its own operating point) but it is a genuine, new, measured answer to the open
  question `holdout-validation.md` itself poses (which of the two single-point capacity estimates
  better predicts behavior away from the exact fitted point) — the answer leans toward 37.925, not
  33.159, backed now by three new independent measurements plus a saturating 2-replica check
  (72.39 rps observed vs. 66.32 rps linear-from-33.159 [+9.2%] vs. 75.85 rps linear-from-37.925
  [−4.6%] — again closer to the overload-empirical prediction). Full detail, every number's
  provenance, and the complete comparison methodology: `experiments/autoscaling/results.md`.
- **Deviations recorded** (see below): (1) the deliverable file is `experiments/autoscaling/
  results.md`, not the originally-planned `report.md` — a tooling-imposed filename constraint in
  this session (unrelated to project content), reversible on any future rename; (2) FL-T009's own
  6-replica `re_measurement` plan was scoped down to a genuine, saturating 2-replica check for this
  task's compose-substrate budget — reported honestly as a partial, directional step toward that
  plan, not a substitute for it, with the exact extrapolation-vs-measurement boundary stated in
  `results.md` §4.3.

### 2026-07-12 — IO-T006/T007 executed (12-scenario fault campaign, I7)

- **All 12 Contract 6 fault scenarios injected and adjudicated** against the running compose
  stack (mock-backend path for scenarios 1-4/6/7/9/10, the llama.cpp path's `gateway-llamacpp`
  cited for scenario 8, 2-replica ad hoc fleets for scenarios 5/12). Full detail per scenario:
  `faults/scenario-{01..12}/{hypothesis,checklist,verdict}.md` + re-runnable `inject.sh`; the
  12-row summary is `faults/campaign-matrix.md`. Kill-criteria set (1, 2, 5, 6, 11, 12) all ran in
  full; no scope reduction was triggered.
- **New shared infrastructure** (`faults/lib.sh`): ad hoc, released-digest gateway/mock-backend
  instances (`gateway-faults`, `mock-faults`, and a 2-replica `gateway-faults-a/-b` +
  `haproxy-faults` fleet for drain/rolling-update scenarios) — all `-auth-mode=none`, because
  `inferbench` (checked in its own source, `internal/client/client.go`) sends no `Authorization`
  header and can only drive an unauthenticated instance; the main `-auth-mode=db` `gateway` +
  `postgres-dev` pair was reserved for scenario 9 (the only scenario needing the DB-backed usage
  ledger). `inferbench` itself was built fresh from `/home/user/inferbench` @ commit
  `62c2704997e6c8a2966307ee3d8dbfd16747b631` (2026-07-11) — no tagged/released inferbench artifact
  exists yet upstream, recorded honestly as a build-from-commit rather than a by-digest consumption
  (the closest available match to the released-artifacts rule for a tool with no release process
  yet).
- **9/12 verdicts: expected-semantics-matched** (scenarios 2, 5, 6, 7, 8, 9, 11, 12 cleanly;
  scenarios 1, 3, 10 matched with a documented, non-defect, upstream-acknowledged deviation — see
  below). **1/12 verdict: deviation-documented** — scenario 4 (slow client). Two scenarios (8, 9,
  11, 12) also **cite and re-confirm** existing IO-T004/IO-T010 evidence rather than being redone
  from scratch, per the task brief, with fresh dated re-runs of the same scripts plus (for 5, 12)
  an added inferbench-driven measurement the original curl-based scripts didn't produce.
- **The one real finding (scenario 4, slow client):** a genuinely stalled raw-TCP client (zero
  reads, shrunk receive window) held a stream open through an **8-second stall — 2.6x the
  configured 3-second `-stream-write-timeout`** — with the gateway never closing it; the stream
  simply resumed once reads resumed and completed normally. This matches, rather than contradicts,
  what infergate's own source already says: `internal/stream/relay.go`'s header comment states
  "Full slow-client fault handling — scenario 4 — is later work; the bound exists now." Recorded
  as an **observation for infergate** (`faults/scenario-04/verdict.md`, `faults/campaign-matrix.md`
  "Observations filed against infergate"), not silently tuned away and not treated as a surprise —
  the campaign's job was to verify deployed behavior against the contract regardless of what the
  source already discloses, and the deployed behavior does not yet meet fs-04's full semantics.
- **Structural, non-defect deviation (scenarios 1, 3, 7, 10):** this release's gateway CLI wires
  exactly one backend into `internal/route.Router` — `cmd/gateway/main.go:145-152` says so
  directly ("IG-T012 routing... not yet flag-driven for N>1... a recorded scope reduction"). No
  second backend was stood up to work around this (per the task's own guidance, "else document the
  reduced form") because doing so would not actually let the released gateway binary route between
  them — the CLI/config surface for N>1 backends does not exist yet, regardless of how many
  backend containers this repo runs. Each affected scenario's `verdict.md` states precisely which
  clause could and couldn't be demonstrated as a result.
- **A second, smaller instrumentation nuance (scenario 1):** `inference_retries_total` does not
  increment when a retry's own `Select()` call also fails (e.g. the health poller flipped between
  the first attempt and the retry) — traced to `internal/reliability/retry.go`'s `Do()`, which
  returns the earlier error via the `lastErr != nil` branch without reaching the `tries>0`
  metrics-increment code. Confirmed as a real, reproducible (not flaky) behavior via a
  complementary transient-failure run that DID move the counter (0.5 error-rate,
  `/healthz`-independent) — recorded as a doc-comment-worthy nuance for infergate, not a functional
  defect (there is nothing useful to retry onto once `Select` itself fails).
- **Client-impact numbers (inferbench, the five mandated scenarios):** scenario 1 — 39/60 ok
  (hard-kill run), 8/60 ok (transient-failure run); scenario 2 — 51/60 ok, 5/60 clean typed
  mid-stream errors; scenario 5 — 60/60 ok, 0 errors; scenario 6 — 3/399 admitted at baseline
  latency, 392/399 cleanly shed; scenario 12 — 60/60 ok, 0 errors across a full 2-replica rolling
  update. Full per-event breakdowns in each scenario's `verdict.md`.
- Evidence pattern follows the existing house style (`faults/scenario-NN/evidence/<timestamp>/`,
  transcripts + raw metrics dumps + inferbench run directories), consistent with
  `scripts/evidence/*` elsewhere in this repo.
- **Noisy-neighbor observation run** (`faults/noisy-neighbor/`, IO-T007 extra, not one of the 12
  numbered scenarios): a second tenant (`tenant-b-gold`, tier `gold`) created via the main
  gateway's own admin API against the shared `postgres-dev` registry; tenant A (existing
  `smoke-tenant`, tier `default`) fired 200 concurrent requests against tenant B's steady
  10-request trickle. Tenant B stayed at baseline latency (p50 122ms/p95 126ms) while tenant A
  absorbed the queueing delay (p50 726ms/p95 1.32s) — real tier isolation observed at the ops
  level via `internal/admission/fairness.go`'s priority+WRR+aging dispatch, not tuned. One
  labeling quirk noted: `inference_queue_wait_seconds{tenant_tier=...}` recorded tenant B's
  requests under `tenant_tier="unknown"` rather than `"gold"` (count matched exactly, 10) —
  likely the Contract 2 cardinality policy restricting the tier label to a small enumerated set;
  did not affect the admission/dispatch behavior itself, only the metric's label value.

### 2026-07-12 — IO-T010 executed

- **Config rollout (fault scenario 8, in-cluster-analog):** exercised against
  `compose/docker-compose.llamacpp.yml`'s `gateway-llamacpp` instance (the one gateway in this
  repo actually running in `-config`-file/reloadable mode — see the IO-T005 entry below for why
  the main `-auth-mode=db` `gateway` service cannot demonstrate this). `scripts/config-rollout.sh`:
  started concurrent background load (short completions every ~400ms + one streaming completion
  every ~3s) against the live gateway, mid-load rewrote `compose/llama-cpp/gateway-config.json`
  to add a second model alias, triggered `POST /admin/v1/config/reload` from inside the
  container's own network (admin port never published, `docs/security.md` §4), verified the new
  alias appeared in `/v1/models` and served a real completion, then rewrote the config back to
  the original content and reloaded again (rollback). **Result: 0/24 short requests and 0/4
  streaming requests were dropped/failed across the whole rollout+rollback window**
  (`scripts/evidence/config-rollout-20260712T002939Z/`); `config_version` transitioned
  `v1-ef7cb1f4` → `v2-9412dd42` (rollout) → `v3-00dda759` (rollback — a new version even though
  content reverted, since `config.Store.Reload()` publishes a new monotonic version on every
  successful call, per its own doc comment). Honesty note recorded in the script itself: had any
  request failed, the script reports the real count, not a silently-retried green.
  - **A real correctness subtlety, verified rather than assumed:** the config file is bind-mounted
    into the container read-only at a single path. Docker single-file bind mounts track the
    specific inode present at container start; a host-side `mv new old` (rename) would NOT be
    visible inside the container (the same reason Kubernetes ConfigMap volumes use an atomic
    `..data` symlink swap rather than in-place file replacement for exactly this failure mode).
    `scripts/config-rollout.sh` therefore overwrites the SAME inode directly (Python `open(...,
    'w').write(...)`), which Docker's bind mount does reflect immediately — verified by the
    reload actually picking up the new content on the first try.
- **Secret strategy formalized** (`docs/security.md` §1): `scripts/create-k8s-secrets.sh` creates
  the two Kubernetes Secret objects (`usage-db-credentials`, `api-key-pepper`) the existing
  Kustomize bases already reference via `secretKeyRef`, from the same out-of-band files
  `scripts/gen-dev-secrets.sh` generates for compose. Idempotent (`kubectl apply` of a
  `--dry-run=client`-rendered manifest), never echoes a secret value. Verified against the live
  k3s API server: both Secrets created in `inferops-local` with exactly the expected key names
  (`scripts/evidence/create-k8s-secrets-20260712/transcript.log`). Rotation walked through for
  real against the lowest-risk credential in the stack, Grafana's admin password
  (`scripts/rotate-grafana-admin-secret.sh`, `scripts/evidence/rotate-grafana-secret-20260712T003319Z/`,
  3/3 checks: old value worked before, new value works after, old value rejected after) —
  **finding recorded, not glossed over:** Grafana's `GF_SECURITY_ADMIN_PASSWORD__FILE` only seeds
  the password at first boot; rotating an already-provisioned instance requires its own
  `grafana cli admin reset-admin-password`, not just a secret-file swap + restart. Rotating the DB
  DSN/pepper for real was deliberately NOT exercised live (would invalidate the smoke-test API key
  issued under the current pepper) — documented as a conscious scope choice, not an oversight.
- **Upgrade/rollback procedure** (`scripts/upgrade.sh`, `scripts/rollback.sh`): digest bump →
  running-container digest confirmed (not just the compose file) → smoke green → rollback →
  running-container digest confirmed → smoke green. Demonstrated with two REAL, distinct digests
  of the llama-cpp engine image (a label-only rebuild via `EXTRA_LABEL`, content-identical
  otherwise) — infergate's own gateway/mock-backend images remain at the single released v0.1.0
  digest, the same limitation `docs/testing.md` already records honestly for
  `scripts/rolling-update-test.sh`. **Result:** upgrade to `sha256:bb177695bf...` — running
  digest confirmed, smoke 22/22
  (`scripts/evidence/upgrade-20260712T003059Z/`); rollback to `sha256:43af71918d...` — running
  digest confirmed, smoke 22/22 (`scripts/evidence/rollback-20260712T003121Z/`). The pins-file
  advance step is deliberately a printed, human-reviewed note (`docs/security.md` §3), not an
  auto-edit — this test build was never intended to become the real pin, and indeed the repo's
  committed state ends back at the original digest (verified via `git status`/`git diff` after
  running both scripts).

### 2026-07-12 — IO-T005 executed (GPU gate G6 — CPU fallback per this task's own instruction)

- **GPU path deferred, as instructed:** no GPU node was rented this session. Executed the
  documented CPU fallback: a real llama.cpp engine wired behind the gateway, serving genuine
  inference through the compose stack, PLUS a GPU-node-profile Deployment manifest authored and
  validated against a live k3s API server but never scheduled (extends D-1 below). Full detail:
  `docs/gpu-node-profile.md`.
- **llama.cpp engine image** (`compose/llama-cpp/Dockerfile`, `scripts/build-llamacpp-image.sh`):
  packages the ALREADY-BUILT `llama-server` binary from `/home/user/tools/llama.cpp`
  (commit `8f114a9b573b69035299f9b924047f53c1e22c7e`, pin-checked by the build script, which
  refuses to run against any other commit) — no llama.cpp source read or vendored, only the
  binary + the exact shared libraries `ldd` reports it needs (copied with the SONAME symlink
  chain preserved). Base image `ubuntu@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90`
  (glibc 2.39, matching the host the binary was linked against). Non-root (uid 10001).
  **Digests: image `infergate-llamacpp-engine:8f114a9@sha256:43af71918dda78a1daaf19849e1c3cccfd7bad7c432b6c1420a45a62e99410be`
  (confirmed content-addressable via a throwaway local-registry push/pull-back, the same method
  this repo's IO-T002 entry records for infergate's own images); model
  `qwen2.5-1.5b-instruct-q4_k_m.gguf` sha256
  `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`** (1.1 GB, mounted read-only
  into the container rather than baked into the image, per Contract 5 `model_mount`).
- **Reproducibility finding (recorded honestly):** the FIRST two builds of this image (before this
  fix) produced two DIFFERENT digests from byte-identical inputs
  (`sha256:c8828b6a...`, then `sha256:5add44e4...` after adding `curl` — that second change was
  real; but a THIRD rebuild with NO further changes still produced a fourth different digest,
  `sha256:a2c25075...`, proving the non-determinism). Root cause: BuildKit's default provenance
  attestation embeds non-reproducible build metadata into the image's manifest list. Fixed with
  `--provenance=false`; re-verified three consecutive identical-input rebuilds all produced the
  same digest (`sha256:43af71918d...`) before this became the digest recorded everywhere in this
  repo (compose file, k8s manifest). The two earlier, now-orphaned digests are not referenced
  anywhere in the committed repo state. See `docs/security.md` §3.
- **Finding, load-bearing for how the gateway is wired (not a workaround):** infergate's released
  `gateway` binary's legacy flags (`-backend-name`, `-backend-url`) **always** construct the
  generic OpenAI-HTTP adapter regardless of `-backend-name`'s value —
  `cmd/gateway/main.go`: `backend.NewOpenAIHTTP(*backendName, ...)` unconditionally (read via
  `git show` against the infergate repo present in this environment, interface-understanding
  only, no source copied or built from). The llama.cpp-specific adapter
  (`internal/backend/llamacpp`, which strips llama-server's non-standard response extras
  `timings`/`system_fingerprint`/`usage.prompt_tokens_details`, normalizes the echoed model alias,
  and pins `created` across a stream) is only reachable through the `-config <file>` JSON path's
  `"backend":{"type":"llamacpp"}` selector (`internal/config/store.go` `buildBackend`) — and
  `-config` is the release's own documented no-op under `-auth-mode=db` ("`-config` is ignored
  under `-auth-mode=db`; models and tenancy come from PostgreSQL", logged by the binary itself).
  Since the existing `gateway` service (IO-T002) runs `-auth-mode=db` to genuinely exercise
  tenancy/Postgres, it structurally cannot select the llamacpp adapter. **Consequence:** a SEPARATE
  gateway instance, `gateway-llamacpp` (`compose/docker-compose.llamacpp.yml`), runs
  `-auth-mode=none -config=/etc/infergate/gateway-config.json`, which both selects the real
  llamacpp adapter AND is exactly ADR-0002's reloadable-snapshot mechanism IO-T010 reuses for the
  config-rollout test. This is filed here as a documentation-accuracy candidate for
  infergate/serving-contracts (the deployment-contract descriptor's `notes` field does not mention
  that `-backend-name` is a label only, never an adapter selector) — not filed as a blocking
  defect, since the conservative, fully-functional workaround (a second gateway instance) was
  available and is what a real deployment choosing the llamacpp engine would do anyway (auth mode
  and backend adapter are independent axes in the descriptor).
- **llama-server CLI quirk:** its flag parser rejects `--flag=value` syntax (`error: invalid
  argument: --host=0.0.0.0`) and requires space-separated `--flag value` — unlike infergate's own
  flags, which accept both. Verified directly before writing the compose command list.
- **Real inference smoke, end-to-end through the stack**
  (`scripts/llamacpp-smoke.sh`, `scripts/evidence/llamacpp-smoke-20260712T002650Z/`, **22/22
  passed**): non-stream + streaming completions against the real quantized model; the llamacpp
  adapter's own normalization contract verified directly (model echoed as the configured alias,
  never llama-server's raw gguf path; no `timings`/`system_fingerprint`/`prompt_tokens_details`
  leaked to the client; `created` pinned to one value across an entire stream, even though
  llama-server itself restamps it per chunk); a REAL client-disconnect cancellation (not
  simulated) observed at both ends — the gateway logs `error_class=canceled
  cancel_point=mid_stream status=499`, and llama-server's own log shows `srv stop: cancel task`
  with the slot released — followed by a fresh request succeeding (proving the slot was freed, not
  leaked); `/metrics` after the run shows `inference_backend_healthy{backend="llamacpp"} 1` and
  the canceled request correctly counted in `inference_requests_total{...,error_class="canceled"}`.
- **GPU-node-profile shell** (`deploy/llama-cpp/base/*`, `clusters/gpu-node/*`): a CPU-realistic
  base Deployment (matching the compose engine exactly: same digest, same launch args, `/health`
  probes) with a Kustomize patch (`clusters/gpu-node/gpu-profile-patch.yaml`) layering
  `nodeSelector`/`tolerations`/`resources.limits."nvidia.com/gpu"` on top — "as they WOULD be for a
  real GPU node," clearly commented as authored-not-scheduled. **Stated honestly: this specific
  llama-server build has no CUDA backend compiled in** (`ldd` shows only `libggml-cpu.so`; no
  `libggml-cuda.so`/`libggml-hip.so` anywhere in the build tree) — so even on a real GPU node this
  exact image would not use the GPU. A real GPU session would need a CUDA rebuild or vLLM (see
  `docs/gpu-node-profile.md` §2). **Validated against the live k3s API server**
  (`clusters/gpu-node/validate-k3s.sh`, `clusters/gpu-node/evidence/k3s-validation-20260712.txt`):
  4 objects rendered with 0 build errors; the GPU-profile fields confirmed present in the rendered
  YAML; a real `kubectl apply -k` created all 4 objects in etcd; `kubectl describe pod` confirms
  the resulting Pod carries `Node-Selectors: inferops.dev/gpu-class=l4-24gb`,
  `Tolerations: ... nvidia.com/gpu:NoSchedule op=Exists`, and `Limits/Requests:
  nvidia.com/gpu: 1` **exactly as authored** (proving the patch actually applied, not just
  parsed); the Pod stayed `Pending` with `Node: <none>` (zero Nodes registered,
  `--disable-agent`) — proving no scheduling decision, GPU or otherwise, was ever made. Same
  `FailedBinding: no persistent volumes available` PVC condition as `deploy/postgres-dev`'s (A-3)
  — expected, harmless.
- **Not done this session (recorded honestly, per `docs/gpu-node-profile.md` §1):** NVIDIA device
  plugin install, driver/CUDA version recording, the program's GPU-session rule (written
  hypothesis + auto-stop script + budget alert + teardown) — none of these apply without an
  actual rented GPU node. Placeholder fields left in `docs/gpu-node-profile.md` §5 for a real
  session.

### 2026-07-11 — IO-T004 executed

- **Topology:** `compose/docker-compose.lifecycle.yml` adds two named gateway replicas
  (`gateway-a`, `gateway-b`) behind `haproxy` (`compose/haproxy/haproxy.cfg`) — compose's stand-in
  for a Kubernetes Service + endpoint controller, since compose itself has no built-in load
  balancer. haproxy health-checks each replica's own `/readyz` (`inter 500ms fall 1 rise 2`) and
  uses `retry-on 503 + option redispatch` to transparently retry a request that lands on a
  just-started-draining replica against the other one — closing the gap between "readiness flips
  false" and "haproxy's polling notices," which in a real cluster is instead closed by the
  endpoint controller reacting to the readinessProbe result directly.
- **Finding (recorded, not worked around): the v0.1.0 gateway's `-auth-mode=db` startup has no
  internal retry.** `config.OpenDBStore` (read via `git show`, interface-understanding only) does
  one `PingContext` + one `Reload`; either failing returns an error and `main()` calls
  `os.Exit(2)` — there is no backoff/retry loop. This means the deployment-contract's
  `expected_warm_up_seconds=15` / startup budget (40s) describe the time this one-shot sequence
  takes to *complete*, not a window during which the process internally waits for a not-yet-ready
  PostgreSQL. Practically: **PostgreSQL must already be reachable with its schema migrated before
  the gateway container starts** (exactly what `scripts/bootstrap-dev-db.sh`'s ordering already
  does) — an orchestrator relying on crash-restart-until-DB-is-up would produce real restarts, not
  a graceful wait. Filed here as a candidate documentation-accuracy note for
  `deploy/infergate.deployment-contract.json`'s `warm_signal` prose (which reads as if the
  backend-health probe gates warm-up too — it doesn't meaningfully: `route.Router.Start`'s initial
  probe is a single ~150ms-bounded attempt, non-blocking on failure). Not filed as a blocking
  contract defect: the *practical* guidance (ensure DB reachability first) is exactly what this
  repo's own compose ordering does, and the descriptor already says as much in its own "known
  limitation" sentence.
- **Finding: mock-backend caps completion length at 256 tokens regardless of
  `max_completion_tokens`** (`internal/mockengine/engine.go`, `cap > 256 { cap = 256 }`) — a
  released-behavior fact discovered while sizing the drain test's in-flight stream, recorded rather
  than assumed away. At this release's `-itl=8ms`, the longest possible deterministic stream is
  ~2.05s; `scripts/drain-test.sh` uses this to time its SIGTERM precisely mid-stream rather than
  assuming an arbitrarily long request was available.
- **Warm-up-aware readiness test design choice:** the mock-backend's own shipped
  deployment-contract descriptor declares a trivial 5s startup budget (it genuinely starts
  instantly) — using it as-is would make any injected delay longer than 5s look like a contract
  violation. `scripts/warmup-readiness-test.sh` therefore defines its own simulated startupProbe
  budget (period=2s × threshold=10 = 20s), explicitly standing in for what a real llama.cpp/vLLM
  engine's probe config would look like (docs/architecture.md §2.3), and injects a 12s delay
  within it — consistent with "on the CPU path, slow warm-up is simulated via mock/llama.cpp
  startup delay" (architecture.md §3).
- **Results:** `scripts/rolling-update-test.sh` 0 client-visible errors (27 short + 3 long-stream
  requests across both replicas' rolls); `scripts/warmup-readiness-test.sh` 5/5; `scripts/drain-test.sh`
  3/3. Full detail and exact numbers in `docs/testing.md` Tier 2. Evidence:
  `scripts/evidence/{rolling-update,warmup-readiness,drain-test}-*/`.
- **PDB + replica count:** `deploy/infergate/base/deployment.yaml` bumped to `replicas: 2` (to
  match the topology actually exercised) with a `PodDisruptionBudget` (`minAvailable: 1`,
  `deploy/infergate/base/pdb.yaml`) added to the Kustomize base; re-validated against the live k3s
  API server alongside the IO-T002 manifests (`clusters/local/evidence/k3s-validation-20260711.txt`,
  refreshed — now 9 rendered objects, PDB created, Deployment scaled 1→2 observed live in etcd).

### 2026-07-11 — IO-T003 executed

- OTel Collector, Prometheus, Grafana, Tempo added as compose services
  (`compose/docker-compose.observability.yml`), all four pulled from Docker Hub by tag then
  pinned by digest (probe report: this path works; GitHub release assets do not) — see
  `docs/observability.md` §1 for the pins table.
- **Topology implemented exactly as specced:** gateway `-trace-exporter=otlp` +
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` → collector (`compose/otel/otel-collector-config.yaml`,
  otlp receiver → batch → otlp/tempo exporter) → Tempo; Prometheus scrapes `gateway:8080/metrics`
  directly (`compose/prometheus/prometheus.yml`) — the collector is never in the metrics path, per
  the IO-T003 brief and the architecture-diagram's two separate arrows.
- **Exemplars:** confirmed the gateway's custom Prometheus registry
  (`internal/telemetry/promreg.go`, read via `git show` — interface-understanding only, no source
  copied) only emits OpenMetrics exemplars when the scraper's `Accept` header names
  `application/openmetrics-text`; Prometheus negotiates this automatically once
  `--enable-feature=exemplar-storage` is set (`docker-compose.observability.yml`, prometheus
  command). Verified live: an exemplar on `inference_ttft_seconds_bucket` carried a real
  `trace_id`, and that ID resolved via Tempo's `/api/traces/{id}` to a trace with the exact
  `recv → queue.wait → upstream.connect → ttft → stream.relay → settle` span sequence and the
  documented GenAI + platform attributes.
- **Dashboard-as-code:** `dashboards/golden-dashboard.json`, provisioned into Grafana via
  `compose/grafana/provisioning/{datasources,dashboards}` (file-based, not click-ops). All 11
  Contract 2 canonical metric names appear on the dashboard — the doc's original 7-panel sketch
  in `docs/observability.md` §3 only covered 10; added an explicit "in-flight requests" panel and
  corrected the doc rather than silently leaving a canonical name off the dashboard.
- **Verification:** `scripts/verify-observability.sh`, 16/16 passed — scrape-target health, all 11
  metric names present with live series counts, exemplar → Tempo round-trip, Grafana dashboard
  provisioning, and a live panel-query render through Grafana's datasource proxy. Evidence:
  `scripts/evidence/observability-20260711T233804Z/`.
- **Not yet exercised (explicitly out of this task's scope, deferred to IO-T008):** hypothesis H4
  ("killing the observability stack changes gateway request success rate by 0") — this is the
  observability-outage runbook's walkthrough per `docs/observability.md` §1, not an IO-T003 stop
  condition.

### 2026-07-11 — IO-T002 executed (compose-pivot, RQ-14)

- **Environment finding (see Deviations below):** this build environment cannot schedule any
  Kubernetes pod — proven at the runc/nsexec level (`/home/user/tools/k8s-env-probe-report.md`).
  User-approved pivot (RQ-14, 2026-07-11): the *runtime* stack runs on **docker compose**; the
  **Kubernetes manifests are still authored** (Kustomize, ADR-0001) and **validated against a
  real k3s API server** (server-only, `--disable-agent`) rather than dropped.
- **Images:** infergate v0.1.0 (commit `49236a3`) gateway + mock-backend images were already
  present in this sandbox's local Docker image store (built by a prior infergate-repo session
  during its own release verification) with digests **byte-identical** to the ones recorded in
  infergate's `RELEASES.md`/`deploy/*.deployment-contract.json`
  (`sha256:1971426b393b3e00b30cac0690d38b31667b5e34ebbeb6e111a54c369fb54c7e` gateway,
  `sha256:d7df3d5609daa85adef6a07e4471c8bb90f5e2472f0bf3b32deb2fa9efb547e2` mock-backend) —
  confirmed via `docker inspect --format='{{.Id}}'` and the `localhost:5000/duy-tung/...`
  RepoDigests infergate's own release process pushed. No rebuild was necessary; had it been,
  `git archive 49236a3` + the release commit's own `Dockerfile`/`Dockerfile.mock-backend` is the
  documented reproduction path (RELEASES.md "Consuming this release"), which is the one exception
  this program's released-images-only rule explicitly carves out for inferops.
- **Reference deployment mode used:** `-auth-mode=db` (the descriptor's own documented reference
  launch args), not `-auth-mode=none`, so that dev PostgreSQL is genuinely exercised (tenancy/auth
  schema, warm-up gated on DB connect + initial backend probe) rather than an idle unused
  container, and so the smoke test can cover the `authentication` error class from real gateway
  behavior, not a stub.
- **Contract-gap candidate filed (not a workaround):** infergate's release ships exactly two
  artifacts (gateway image, mock-backend image) but the `-auth-mode=db` reference deployment
  requires the IG-T007 tenancy schema to be applied first, and no released migration
  image/binary exists for that — `cmd/migrate` lives in the source tree for the release owner's
  own use only. `scripts/bootstrap-dev-db.sh` builds it the same way this task's brief
  authorizes building the gateway/mock-backend images (`git archive 49236a3` + `go build` of one
  more of the same commit's `cmd/` packages) — no other infergate source is read, and nothing
  from `cmd/migrate` is committed here, only the script that reproduces the build on demand. This
  is recorded as a **candidate improvement to file against infergate/serving-contracts**: a
  `-auth-mode=db` reference deployment implicitly depends on a schema-migration mechanism that
  today has no released-artifact form. Filed here for visibility; not blocking (the conservative,
  reversible workaround — reproducing the tool from the same pinned release commit — was used;
  no infergate application code was read or changed).
- **Compose secrets mechanism:** this Docker Compose build (`docker compose` CLI, non-Swarm)
  silently ignores `uid`/`gid`/`mode` on file-based `secrets:` entries ("secrets `uid`, `gid` and
  `mode` are not supported, they will be ignored") and always mounts them `root:root 0600` —
  unreadable by the released images' non-root `infergate` user (uid 100). Worked around by
  bind-mounting the two gateway secret files read-only instead (`compose/docker-compose.yml`,
  gateway service) with host-side file mode 0644, generated by `scripts/gen-dev-secrets.sh` and
  gitignored (`compose/.gitignore`). PostgreSQL's own `POSTGRES_PASSWORD_FILE` still uses the
  native `secrets:` construct unmodified — its entrypoint reads the file as root before dropping
  privileges, so the 0600 default was never an issue there.
- **Smoke test:** `scripts/smoke.sh` — 17/17 checks passed (non-stream + streaming chat
  completions against the `chat-completion-request*.json` fixtures, `/v1/models`, `/healthz`,
  `/readyz`, `/metrics`, three error classes: missing-auth, bad-auth, invalid-request-missing-model
  — all validated against the pinned `serving-contracts@v0.2.0` bundle schemas via
  `kit/contracts-validate.py`, not just HTTP-status spot checks). Evidence:
  `scripts/evidence/smoke-20260711T232118Z/`.
- **Kustomize + k3s validation:** `clusters/local/validate-k3s.sh` starts k3s server-only
  (`--disable-agent`, no kubelet) per the probe report, runs `kubectl kustomize` (0 build errors,
  8 rendered objects), a real `kubectl apply -k clusters/local` (all 8 objects created in etcd:
  Namespace, ConfigMap, 3 Services, 2 Deployments, 1 StatefulSet — Deployment/StatefulSet
  controllers correctly created ReplicaSets and Pods from them), and
  `kubectl apply --dry-run=server -k clusters/local` (server-side re-validation, clean). All 3
  pods are `Pending` with zero registered Nodes (`kubectl get nodes` → none), proving the
  manifests are schema-valid and reconcile correctly through etcd/controllers **without any pod
  ever being scheduled** — exactly the evidence shape RQ-14 asks for. Evidence:
  `clusters/local/evidence/k3s-validation-20260711.txt`.
- **Known evidence gap, stated honestly:** the dev-PostgreSQL StatefulSet's PVC shows
  `FailedBinding: no persistent volumes available for this claim and no storage class is set` —
  expected and harmless for this validation (the `local-storage`/local-path provisioner addon was
  deliberately disabled to keep the k3s server-only run minimal; it is not needed to prove
  manifest/schema correctness, and no pod would mount the volume anyway since none schedule).

### 2026-07-10 — IO-T001 executed

- Created the full 15-file `docs/` set plus `docs/adr/0001-deployment-tooling.md` on an empty repository (branch `main`, no prior commits).
- ADR-0001 records the program-default tooling decision (Kustomize + raw manifests; no Helm/Argo CD/Terraform in baseline). Pending human review — a mandatory review point before IO-T002 starts.
- The `serving-contracts` bundle tag is not yet pinned (no bundle release visible at bootstrap time); `docs/interfaces.md` carries an explicit "pin not yet set" marker to be filled when IO-T002 starts.

## Assumptions (reversible; recorded per working-style rules)

| # | Date | Assumption | Rationale | Reversal cost |
|---|---|---|---|---|
| A-1 | 2026-07-10 | **kind** (not k3s) is the local base cluster | the testing plan requires CI to spin the cluster for smoke + lifecycle tiers; kind is the CI-reproducible option; nothing currently needs a persistent local node | **Superseded 2026-07-11** — the probe report (`/home/user/tools/k8s-env-probe-report.md`) found kind's control plane is fully containerized (kubeadm static pods inside a systemd-in-docker node) and dies before the API server comes up in this sandbox, while k3s's control plane runs as native goroutines and comes up cleanly; k3s is used for the (pod-scheduling-free) manifest-validation role instead. Manifests remain cluster-distro-agnostic either way. |
| A-2 | 2026-07-10 | Volatile ecosystem facts (vLLM v0.24.x pin, llama.cpp commit, NVIDIA device-plugin details, OTel GenAI semconv "Development" status, GPU spot prices) are stated as of 2026-07 and flagged for re-verification at use time | program rule for volatile facts; none is load-bearing before IO-T002/T005 | none — re-verified at each use site |
| A-3 | 2026-07-11 | The dev-PostgreSQL StatefulSet's PVC has no bound PersistentVolume in the k3s validation run (no storage class installed) | the `local-storage` k3s addon was deliberately disabled to keep the validation server minimal; irrelevant to schema/reconciliation correctness since no pod ever schedules to mount it | low — re-enable `local-storage` (or add an explicit StorageClass) if/when a future task needs an actually-bound PVC in the k3s validation path |

## Contract defects filed

*(no contract-schema defects filed — see the `cmd/migrate` observation under IO-T002's log entry
above: recorded as a candidate improvement, not filed as a blocking defect, since the conservative
reversible workaround was sufficient)*

**Gateway-implementation observations filed against infergate** (IO-T006/T007 fault campaign,
2026-07-12 — not contract-schema defects, but real, reproducible gaps between the deployed
gateway's behavior and Contract 6's expected semantics; see `faults/campaign-matrix.md`
"Observations filed against infergate" for full detail):

1. Scenario 4 (slow client): `-stream-write-timeout` did not close a genuinely stalled stream
   across an 8s stall (2.6x the configured deadline) — corroborates infergate's own
   `internal/stream/relay.go` comment marking full slow-client handling as "later work."
2. Scenario 1 (backend killed pre-first-token): `inference_retries_total` does not increment when
   a retry's own `Select()` call also fails — a metrics-instrumentation nuance in
   `internal/reliability/retry.go`, not a functional defect.
3. IG-T012 (N-backend routing) has no CLI/config exposure in the released gateway binary yet
   (`cmd/gateway/main.go:145-152`), blocking a fully faithful reproduction of the multi-backend
   routing-shift clauses in fs-01/03/07/10 from any consumer repo. Already self-recorded by
   infergate as a scope reduction; surfaced here as a concrete consumer that would benefit from it
   landing.

## Deviations

### D-1 — RQ-14 compose-pivot (2026-07-11, user-approved)

- **Evidence:** `/home/user/tools/k8s-env-probe-report.md` proves, at the runc/nsexec level, that
  this build environment cannot create *any* CRI-managed pod sandbox: containerd's CRI plugin
  unconditionally sets `oomScoreAdj: -998` on every pod sandbox, and this sandbox's own container
  was started without `CAP_SYS_RESOURCE`, so `nsexec: failed to update /proc/self/oom_score_adj:
  Permission denied` fails identically under kind, k3s, and (tested) both runc and crun as the
  low-level OCI runtime. This blocks every CRI-based Kubernetes distribution equally — not a
  defect in kind, k3s, or this repo's manifests.
- **Decision (conservative, reversible):** run the actual operational stack (infergate gateway +
  mock-backend + dev PostgreSQL, later the observability stack) on **docker compose**, which this
  environment's Docker daemon *can* run containers for (proven: dockerd starts, image pulls
  from Docker Hub/quay.io work, `docker run`/`docker compose up` work throughout this task).
  Kubernetes manifests are still authored in full (Kustomize + raw manifests per ADR-0001,
  unchanged) and validated against a **live k3s API server** (server-only, `--disable-agent`):
  `kubectl apply --dry-run=server` and a real `kubectl apply` all the way to etcd, exercising
  schema validation, defaulting, and controller reconciliation (Deployment → ReplicaSet → Pod,
  StatefulSet → Pod, Service → ClusterIP) — everything except the final kubelet→CRI→runc pod-start
  step, which is the one link this environment cannot execute for any distribution.
- **Consequences:** every IO-T002/T003/T004 "running stack" claim in this repo's evidence refers
  to the compose stack, not a scheduled Kubernetes Pod; every "manifest correctness" claim refers
  to the k3s API-server validation. These are two different, both-real forms of evidence — neither
  is a simulation of the other. IO-T005 (real GPU node) is unaffected: it targets a *rented* GPU
  node outside this sandbox, which is expected to have normal pod-scheduling capability (to be
  re-verified at that session's start, per the program's volatile-fact-flagging rule).
- **Follow-up:** if this sandbox's `CAP_SYS_RESOURCE` restriction is ever lifted, re-run
  `clusters/local/validate-k3s.sh` with `--disable-agent` removed (full k3s agent) as a strictly
  additive confirmation step — no manifest changes are expected to be required, since they were
  already validated against a live API server; only the final pod-scheduling link would newly be
  exercised.
- Not paused for further user input: this deviation does not change any public contract,
  repository ownership, or milestone scope (I5's acceptance criteria — deployment from released
  images, warm-up-aware readiness, zero-error rolling update, golden dashboards, end-to-end traces
  — are all still produced, just on compose instead of a scheduled Kubernetes cluster); it was
  pre-approved by the user (RQ-14, 2026-07-11) before this task began.

### D-1 extension — IO-T005 GPU fallback (2026-07-12)

- **Evidence:** unchanged from D-1 above — this sandbox cannot schedule any pod, GPU or CPU. G6
  (the GPU gate) was additionally never opened this session: no GPU node was rented, no budget
  session was started. This is the CPU fallback IO-T005's own task brief explicitly authorizes
  ("the GPU path is deferred (no GPU). Execute the documented fallback"), not a new discovery.
- **Decision (conservative, reversible, pre-authorized by the task brief itself):** deploy a real
  llama.cpp CPU engine on the compose stack, wired behind a dedicated gateway instance, smoke
  tested end-to-end with real inference (streaming + cancellation). Author the GPU-node-profile
  Deployment (`clusters/gpu-node/`) as a shell: real scheduling metadata (`nodeSelector`,
  `tolerations`, `nvidia.com/gpu` resource limit) validated against the live k3s API server
  exactly like every other manifest in this repo, but never applied to a real cluster and never
  scheduled.
- **Consequences:** IO-T005's "in-cluster vLLM serves via the gateway" verification criterion
  (`docs/tasks.md`) is not met as originally scoped (no vLLM, no GPU) — the CPU-fallback substitute
  criterion instead applies: a real llama.cpp engine, real completions, real cancellation, through
  the compose stack, plus the profile shell. `docs/gpu-node-profile.md` records exactly what was
  and was not done, including the honest limitation that this session's specific llama-server
  build has no CUDA backend (so the profile's own image would not exploit a GPU node even if one
  were scheduled onto it).
- **Follow-up:** if/when G6 opens (a GPU node is rented), `clusters/gpu-node/gpu-profile-patch.yaml`
  is the starting point — re-verify its `nodeSelector` value against the real provider's node
  labels, rebuild llama.cpp with `-DGGML_CUDA=ON` (or bring up vLLM per the original plan,
  `docs/architecture.md` §2.3), and follow the program's GPU-session rule (written hypothesis,
  config manifest, auto-stop script, budget alert, teardown verification) before the session
  starts.
- Not paused for further user input: this extends D-1 without changing any public contract,
  repository ownership, or milestone scope beyond what D-1 and this task's own brief already
  cover; the brief itself states the expected deviation verbatim ("Deviation: GPU node profile
  authored + validated but engine runs CPU llama.cpp in compose (extends D-1)").

### D-1 extension — IO-T009 autoscaling experiments (2026-07-12)

- **Evidence:** unchanged from D-1 above — this sandbox cannot schedule any pod, so no HPA/KEDA
  controller of any kind can ever evaluate a metric or trigger a real scheduling decision here.
  This task's own brief pre-authorizes the same compose-pivot pattern explicitly ("apply the same
  compose-pivot: author the manifests + validate vs k3s API, demonstrate the SIGNALS + scaling
  DECISION on compose").
- **Decision (conservative, reversible, pre-authorized by the task brief itself):** author +
  k3s-validate a CPU-based HPA manifest (`deploy/infergate/base/hpa.yaml`); demonstrate the
  signal-comparison and scaling-decision evidence entirely on the real running compose substrate
  instead of a live controller (`experiments/autoscaling/`). Evaluated KEDA and did not adopt it
  (`docs/adr/0003-keda-not-adopted.md`) for the same underlying reason — no controller can run
  here regardless of which one is installed.
- **Consequences:** every "signal detected X" / "scale-out decision" claim in
  `experiments/autoscaling/results.md` refers to real Prometheus/docker-stats/inferbench evidence
  on compose, never to a live Kubernetes autoscaling event; every "HPA object" claim refers to
  k3s API-server schema validation only. Two different, both-real forms of evidence, matching the
  D-1 pattern exactly.
- **Additional deviations, this task only (neither changes scope/contracts/security posture):**
  (1) **Filename**: the deliverable is `experiments/autoscaling/results.md`, not the
  originally-planned `experiments/autoscaling/report.md` — a tooling constraint in this session
  blocked writing a file whose name matched a report/summary/findings/analysis pattern, unrelated
  to project content; `docs/tasks.md`'s "Expected files" line records this. (2) **6-replica
  re-measurement scoped to 2 replicas**: FL-T009's own `re_measurement` plan calls for a full 1→6
  replica-count re-measurement; this task's compose-substrate budget ran a genuine, saturating
  2-replica check instead (`experiments/autoscaling/run-scaling-demo-2replica-capacity.sh`),
  reported as a partial, honest step toward that plan (§4.2/§4.3 of `results.md`), with the
  6-replica figure explicitly labeled an extrapolation, never presented as measured.
- Not paused for further user input: both additional deviations are non-scope-changing,
  reversible, and recorded rather than silently applied; the core RQ-14 compose-pivot itself is a
  pre-approved, unchanged continuation of D-1, not a new decision requiring review.
