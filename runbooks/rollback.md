# Runbook: Rollback

**Evidence base:** IO-T010 (`docs/implementation-notes.md` "2026-07-12 — IO-T010 executed"),
`scripts/rollback.sh`, `docs/security.md` §3 ("Rollback = previous digest, same procedure").

## Symptoms / Trigger

An upgrade (see `upgrade.md`) has gone live and either failed its smoke gate, or a
performance/behavioral regression was found after the fact (see `performance-regression.md` for
diagnosis) and the fastest safe mitigation is reverting to the last-known-good digest.

## Preconditions

- A prior `upgrade.sh` run for the same component recorded its previous digest in
  `scripts/evidence/upgrade-rollback-state/<component>.previous-digest`. If this state file does
  not exist (e.g. rolling back a Kubernetes Deployment days after the last `upgrade.sh` run, in a
  fresh session), fall back to the manual path below.
- The previous digest's image is still available locally (or re-pullable) — do not delete a
  digest's local image immediately after upgrading past it.

## Procedure

**A. Scripted path (state file present — this repo's exercised case, llama.cpp engine):**
```
scripts/rollback.sh
```
This reads `scripts/evidence/upgrade-rollback-state/llama-cpp.previous-digest`, reverts
`compose/docker-compose.llamacpp.yml`'s digest pin to it, redeploys
(`docker compose --profile llamacpp up -d llama-cpp`), confirms the **running container** (not just
the compose file) is back on the previous digest, then re-runs `scripts/llamacpp-smoke.sh`.

**B. Manual path (no state file, or a real Kubernetes cluster):**
1. Look up the last-known-good digest from the inference-lab pins file / prior release evidence
   (never guess — a wrong "previous" digest is worse than no rollback).
2. Revert the digest pin: `sed` the manifest/compose `image:`/`@sha256:...` line, or
   `kubectl set image deployment/<name> <container>=<image>@<previous-digest>`.
3. Redeploy and wait for health: `docker compose up -d <service>` /
   `kubectl rollout status deployment/<name>`.
4. Confirm the **running** container/pod digest matches the previous digest (never trust the
   manifest file alone — see `upgrade.md` step 4 for why).
5. Run the appropriate smoke gate (`scripts/smoke.sh` or `scripts/llamacpp-smoke.sh`).

## Verification

- Running-container digest confirmed equal to the previous (rolled-back-to) digest.
- Smoke green on the reverted digest.
- This repo's last real run: rolled back to `sha256:43af71918dda78a1daaf19849e1c3cccfd7bad7c432b6c1420a45a62e99410be`
  — running digest confirmed, smoke **22/22** (`scripts/evidence/rollback-20260712T003121Z/`).
- Idempotency: re-running rollback when already on the previous digest is a safe no-op
  (`scripts/rollback.sh` logs `NOTE: already at the previous digest` and still re-confirms + re-smokes).

## Rollback / Escalation

- If smoke **still fails after rolling back**, the problem is not the digest — this now indicates
  an environment/dependency issue (DB unreachable, config drift, secret rotated out from under the
  gateway, etc.). Escalate to the relevant runbook: `database-outage.md` if the DB is implicated,
  `config-rollback.md` if a config change landed independently of the image upgrade,
  `backend-failure.md` if a backend/engine is down.
- If no previous-digest record exists anywhere (state file missing AND no pins-file history), this
  is an evidence gap to close before attempting a blind rollback — do not roll back to an
  unverified digest.

## Walkthrough

**Live-cited.** `scripts/evidence/rollback-20260712T003121Z/`: rolled back from the upgrade
candidate digest to `sha256:43af71918d...` — running-container digest confirmed, smoke **22/22
passed**. Chained directly after the `upgrade.md` walkthrough in the same session, using the exact
state file `scripts/upgrade.sh` produced, proving the two scripts compose correctly end-to-end
(upgrade → verify → rollback → verify), not just individually.
