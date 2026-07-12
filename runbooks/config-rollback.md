# Runbook: Config Rollback

**Evidence base:** IO-T010 (`docs/implementation-notes.md` "2026-07-12 — IO-T010 executed"),
`scripts/config-rollout.sh`, fault scenario 8 (`faults/scenario-08/`), ADR-0002.

## Symptoms / Trigger

A config rollout (new model alias, admission tuning, backend routing change) produces unexpected
behavior — a bad alias, wrong admission caps, an unintended backend selection — and needs
reverting to the last-known-good config, ideally without dropping in-flight or newly-arriving
traffic.

## Preconditions

- **The target gateway instance must actually be running in reloadable-config mode**
  (`-config=<file>`). This is a real, load-bearing precondition, not a formality: the main
  `-auth-mode=db` `gateway` service's `-config` flag is a **documented no-op** under
  `-auth-mode=db` — "models and tenancy come from PostgreSQL," logged by the binary itself
  (`docs/implementation-notes.md` IO-T005 entry). Config-reload rollback as described here only
  works against an instance like `gateway-llamacpp`
  (`compose/docker-compose.llamacpp.yml`, `-auth-mode=none -config=<file>`). For a `-auth-mode=db`
  instance, a "config" change is really a schema/admin-API change — different rollback path,
  outside this runbook's scope.
- A copy of the last-known-good config file content, taken **before** any rollout (this repo's
  script keeps the pre-rollout content in a shell variable and restores it verbatim; in a real
  operation, keep a copy in version control or a backup file).
- The admin reload endpoint is reachable only from inside the container's own network — it is
  never published externally (`docs/security.md` §4) — so rollback must be triggered via
  `docker exec` (or the cluster-internal equivalent), never a host-exposed port.

## Procedure

1. **Locate the mounted config file's host path** (e.g.
   `compose/llama-cpp/gateway-config.json`) and confirm which content is currently live by reading
   the gateway's own log for its last `config_version`:
   ```
   docker logs <gateway-container> 2>&1 | grep -o 'config_version=[^ ]*' | tail -1
   ```
2. **Overwrite the SAME inode with the previous known-good content** — do **not** `mv`/rename a
   replacement file onto the mounted path:
   ```
   printf '%s' "$PREVIOUS_CONFIG_CONTENT" > <config-file-path>
   ```
   This matters mechanically: a Docker single-file bind mount (and a Kubernetes ConfigMap
   `subPath` volume) tracks the specific inode present at container start, not the path — a
   host-side rename-replace would silently **not** be visible inside the container. Writing in
   place to the same inode is the only reliable way for the running process to see the reverted
   content at all. (This is the exact reason Kubernetes ConfigMap volumes use an atomic `..data`
   symlink swap at the directory level for non-`subPath` mounts — a `subPath` mount, like this
   single-file bind mount, does not get that protection.)
3. **Trigger the reload** from inside the container's own network:
   ```
   docker exec <gateway-container> wget -q -O - --post-data='' http://127.0.0.1:8090/admin/v1/config/reload
   ```
   The response includes the new `config_version` — `config.Store.Reload()` publishes a fresh
   monotonic version on **every** successful call, even when the content reverts to something seen
   before (i.e. rolling back still advances the version number; that is expected, not a bug).
4. **Verify the reverted content is actually live**: check `/v1/models` no longer lists the bad
   alias, and/or a request against the previously-added (bad) alias now fails as expected.

## Verification

- `config_version` advanced to a new value after the rollback reload (confirms the swap actually
  happened, not just that the file changed on disk).
- `/v1/models` reflects the reverted (last-known-good) model list.
- Concurrent background traffic run during the rollback window shows **zero dropped requests** —
  this is the core Contract 6 scenario-8 guarantee (`config.Store.Reload()`'s atomic-pointer
  snapshot swap: in-flight requests keep running against whichever snapshot they captured at
  dispatch; only requests arriving after the swap see the new one).

## Rollback / Escalation

- Rolling back is itself instant and idempotent — if the "previous" content restored was *also*
  wrong, repeat step 2 with an even earlier known-good copy; there is no separate "rollback of the
  rollback" mechanism needed.
- If `config_version` does **not** advance, or the reload endpoint errors: most likely the config
  file at the exact mounted path was not actually rewritten (check the mount's target path
  precisely — a typo writing to a different path than the bind mount's source is a real, easy
  mistake), or the target instance is not actually running in reloadable-config mode (see
  Preconditions). If reload genuinely does not work even against a correctly-configured instance,
  escalate to a full component restart with the corrected config baked into the deploy artifact
  instead of relying on hot-reload, and file the reload failure as a defect.

## Walkthrough

**Live-cited.** `scripts/evidence/config-rollout-20260712T002939Z/`: a rollout (new model alias
added) followed immediately by a rollback (reverted to original content) under continuous
background traffic (short completions ~every 400ms + one streaming completion ~every 3s) —
**0/24 short requests and 0/4 streaming requests dropped** across the whole rollout+rollback
window; `config_version` transitioned `v1-ef7cb1f4` → `v2-9412dd42` (rollout) →
`v3-00dda759` (rollback — a new version even though content reverted, exactly as described above).

Fault scenario 8 (`faults/scenario-08/`, cited and re-confirmed twice fresh per
`faults/campaign-matrix.md`) ran the identical mechanism three independent times total: **0 dropped
requests every time** (71 short + 12 stream requests cumulative across all runs), `config_version`
advancing monotonically v1→v7, swap latency in the hundreds of microseconds — the strongest-
evidenced scenario in the entire fault campaign.
