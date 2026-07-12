# Runbook: Upgrade

**Evidence base:** IO-T010 (`docs/implementation-notes.md` "2026-07-12 — IO-T010 executed"),
`scripts/upgrade.sh`, `docs/security.md` §3.

## Symptoms / Trigger

A planned upgrade: a new released digest for a component (gateway, mock-backend, or an engine like
llama.cpp) needs to go live.

## Preconditions

- The new digest is a **released artifact**, not a local build from source (the one carved-out
  exception in this repo is the llama.cpp engine image, which inferops builds+owns per
  `docs/gpu-node-profile.md` — infergate's own gateway/mock-backend images are never built here).
- Smoke tooling for the target component exists and is green against the *current* digest before
  starting (`scripts/smoke.sh` for the gateway/mock-backend path, `scripts/llamacpp-smoke.sh` for
  the llama.cpp path).
- **Known limitation, stated honestly:** infergate's v0.1.0 release has shipped exactly one image
  digest for the gateway and mock-backend — there is no second released digest to upgrade *to* for
  those two components yet. This procedure is fully exercised end-to-end against the llama.cpp
  engine image (the one component in this repo with two real, distinct digests available); the
  identical mechanics apply verbatim to a future infergate digest bump, per
  `docs/testing.md`'s own note on `scripts/rolling-update-test.sh`.

## Procedure

1. **Record the current (pre-upgrade) digest** — read directly from the running artifact, not
   assumed from a doc:
   ```
   grep -o 'infergate-llamacpp-engine@sha256:[0-9a-f]*' compose/docker-compose.llamacpp.yml
   ```
2. **Obtain/build the new digest.** For the llama.cpp engine (this repo's exercised case):
   ```
   IMAGE_TAG=<new-tag> scripts/build-llamacpp-image.sh
   docker inspect --format='{{index .RepoDigests 0}}' <new-tag>
   ```
   For a real infergate digest bump: pull the new released digest per its own release notes — no
   local build.
3. **Update the digest pin** in the manifest/compose file (`sed` on the pinned `@sha256:...`
   string, or the Kustomize base's `image:` line for a real cluster) and deploy:
   ```
   docker compose --profile llamacpp up -d <service>
   ```
   Kubernetes equivalent: `kubectl set image deployment/<name> <container>=<image>@<new-digest>`
   or `kubectl apply -k` after editing the base, then `kubectl rollout status deployment/<name>`.
4. **Confirm the RUNNING container is actually on the new digest** — not just the compose/manifest
   file:
   ```
   RUNNING_IMAGE=$(docker inspect --format='{{.Image}}' <container>)
   docker inspect --format='{{index .RepoDigests 0}}' "$RUNNING_IMAGE"
   ```
   This step matters: a compose file edit alone proves nothing about what's actually serving
   traffic.
5. **Run the smoke gate** against the upgraded digest (`scripts/llamacpp-smoke.sh` for llama.cpp,
   `scripts/smoke.sh` for the gateway/mock-backend path). Do not proceed to step 6 unless smoke is
   green.
6. **Advance the pins-file note** — a **human-reviewed step, never auto-edited** by the script
   (`docs/security.md` §3): update the digest recorded in `docs/implementation-notes.md` /
   inference-lab's pins file to the new digest, with the smoke evidence path as justification.

## Verification

- Running-container digest confirmed equal to the new digest (step 4, do not skip).
- Smoke green on the new digest.
- This repo's last real run: upgrade to `sha256:bb177695bf...` — running digest confirmed, smoke
  **22/22** (`scripts/evidence/upgrade-20260712T003059Z/`).

## Rollback / Escalation

- If smoke fails on the new digest: **do not advance the pins-file note.** Proceed immediately to
  `rollback.md` — the state file `scripts/evidence/upgrade-rollback-state/<component>.previous-digest`
  this script writes is exactly what `scripts/rollback.sh` consumes.
- If the running-container digest check (step 4) does not match the intended new digest: the
  deploy did not actually take effect (stale compose cache, wrong compose profile, etc.) — do not
  treat this as a functional regression; re-run the deploy step before drawing any conclusion from
  smoke output on the wrong artifact.
- A smoke failure that traces to a genuine behavioral change in the new release (not a deploy
  mechanics problem) is a defect to file against the releasing component, in addition to rolling
  back locally.

## Walkthrough

**Live-cited.** `scripts/evidence/upgrade-20260712T003059Z/`: current digest
`sha256:43af71918dda78a1daaf19849e1c3cccfd7bad7c432b6c1420a45a62e99410be` → candidate digest
`sha256:bb177695bf...` (label-only rebuild of the identical pinned llama.cpp commit — content-
identical except metadata, chosen specifically so the digest-bump *mechanics* could be exercised
for real without an actual functional change to smoke against) → running-container digest
confirmed on the new value → `scripts/llamacpp-smoke.sh` **22/22 passed**. Pins-file advance was
deliberately left as a printed, human-reviewed note (this test build was never intended to become
the real pin) — the repo's committed state ends back at the original digest, confirmed via
`git status`/`git diff` after the full upgrade+rollback sequence.
