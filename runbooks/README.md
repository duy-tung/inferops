# Runbooks — inferops (IO-T008)

Ten operational runbooks, each authored from procedures this repo has actually exercised and
evidenced — none invented. Every runbook states its preconditions, a step-by-step procedure with
real commands, verification, and a rollback/escalation path, plus a **Walkthrough** section
honestly labeled **live-cited** (the exact procedure was run for real, evidence linked) or
**tabletop** (traced step-by-step against the real scripts/manifests/source-reading this repo
already did, but not independently re-executed in this session).

Per `docs/tasks.md` IO-T008, the Google SRE overload/cascading-failures review lens (retry
amplification, load shedding, cascade containment) is applied explicitly in
[`backend-failure.md`](backend-failure.md), [`capacity-shortfall.md`](capacity-shortfall.md), and
[`performance-regression.md`](performance-regression.md).

**A note on environment (RQ-14):** this build sandbox cannot schedule a Kubernetes pod
(`docs/implementation-notes.md` Deviations D-1) — every task in this repo runs its operational
stack on **docker compose** while manifests are authored and validated separately against a live
k3s API server. These runbooks reflect that: commands are the real compose commands this repo's
scripts actually run, with the Kubernetes-equivalent command noted alongside wherever the two
differ (e.g. `kubectl scale`, `kubectl rollout restart`, `kubectl delete pod --grace-period`).
Neither form of evidence stands in for the other; both are stated as what they are.

## Index

| # | Runbook | Trigger | Primary evidence | Walkthrough |
|---|---|---|---|---|
| 1 | [deploy.md](deploy.md) | Fresh stack stand-up | IO-T002 (`scripts/smoke.sh`) | live-cited |
| 2 | [upgrade.md](upgrade.md) | Planned digest bump | IO-T010 (`scripts/upgrade.sh`) | live-cited |
| 3 | [rollback.md](rollback.md) | Upgrade regressed / bad digest | IO-T010 (`scripts/rollback.sh`) | live-cited |
| 4 | [drain.md](drain.md) | Planned replica/node removal | IO-T004 (`scripts/drain-test.sh`) | live-cited |
| 5 | [backend-failure.md](backend-failure.md) | Backend down/unhealthy | Fault scenarios 1, 2, 10 | live-cited |
| 6 | [performance-regression.md](performance-regression.md) | Latency/goodput regression | IO-T009 signal comparison + fleetlab corpus | tabletop |
| 7 | [config-rollback.md](config-rollback.md) | Bad config rollout | IO-T010 (`scripts/config-rollout.sh`) + fault scenario 8 | live-cited |
| 8 | [capacity-shortfall.md](capacity-shortfall.md) | Sustained shedding / overload | IO-T009 scaling demo | live-cited |
| 9 | [observability-outage.md](observability-outage.md) | Prometheus/Grafana/Tempo/Collector down | IO-T003 stack (H4) | tabletop |
| 10 | [database-outage.md](database-outage.md) | usage-ledger PostgreSQL down | Fault scenario 9 | live-cited (steady-state) / tabletop (startup-time case) |

## Deviation from the original expected-files list (recorded here, not silently)

`docs/tasks.md`'s IO-T008 entry lists `runbooks/walkthroughs/*.md` as a separate expected-files
group. This delivery embeds each runbook's walkthrough as an in-file **Walkthrough** section
instead of a parallel `walkthroughs/` directory — the two would otherwise duplicate the same
evidence links, and an operator reading a runbook during an incident benefits from the walkthrough
notes (what was actually run, what gaps remain) living next to the procedure itself rather than in
a separate file they'd have to cross-reference. Recorded per the program's deviation policy
(conservative, reversible, does not change scope/contracts/security posture) in
`docs/implementation-notes.md`.

## Gaps found while authoring these runbooks (surfaced, not hidden)

- **observability-outage.md's live walkthrough (hypothesis H4) is still not executed.** This
  session attempted it (baseline traffic confirmed healthy, then attempted to stop the four
  observability containers) but the harness's own workload-safety guard declined to kill shared
  containers not created this session, on a stack another agent could be using — correctly so,
  per this task's own instruction not to disrupt the shared stack. The runbook is traced in full
  (tabletop) against the real architecture (pull-based Prometheus scraping, async OTLP export) and
  a real read-only health confirmation performed today, but the actual "kill the collector, watch
  the success rate stay flat" run remains open. This is the same gap `docs/observability.md` §1
  already flagged as deferred to this task.
- **performance-regression.md has no live incident to cite.** IO-T009 produced the reference
  capacity/latency corpus and the signal-detection comparison this runbook's diagnosis steps lean
  on, but no actual regression was ever triggered and chased down end-to-end in this repo's
  evidence. Marked tabletop accordingly.
- **database-outage.md's "DB down at gateway startup" case (Case B) is tabletop**, distinct from
  the steady-state case (Case A), which fault scenario 9 exercised live. IO-T004's finding that
  `-auth-mode=db` startup has no internal DB retry is real and load-bearing (git-show-verified
  interface reading, not assumed), but this specific runbook was not live-triggered by actually
  crashing the gateway's DB dependency at startup time in this session.
