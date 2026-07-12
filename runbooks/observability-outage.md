# Runbook: Observability Outage

**Evidence base:** IO-T003 (`docs/observability.md` §1, hypothesis H4), `scripts/verify-observability.sh`,
`compose/docker-compose.observability.yml`, `compose/prometheus/prometheus.yml`.

## Symptoms / Trigger

Grafana/Prometheus/Tempo/OTel Collector unreachable, dashboards blank or stale, alerting dark. The
question this runbook answers first: **is the request path actually affected, or only visibility
into it?** By design (hypothesis H4, `docs/observability.md` §1: "the stack is off the request
path"), it should be only the latter.

## Preconditions / why this should be safe by architecture

- **Metrics are pull-based.** Prometheus scrapes the gateway's `/metrics` endpoint
  (`compose/prometheus/prometheus.yml`) — the gateway maintains its own in-process counter/
  histogram registry regardless of whether anything ever scrapes it. A Prometheus outage cannot
  affect gateway behavior at all, only an operator's visibility into it.
- **Trace export is asynchronous.** The gateway exports OTLP spans to the Collector
  (`OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`) via its own batching pipeline,
  decoupled from the request-handling path — a Collector outage means spans queue/drop
  client-side (in the gateway's exporter), not that request handling blocks waiting for the
  Collector.
- **Grafana and Tempo are pure read-path UIs** with zero interaction with the gateway's request
  path — their outage affects only an operator's ability to look at things.

## Diagnosis

1. Confirm which observability component(s) are actually down:
   ```
   docker compose ps        # or: kubectl get pods -n observability
   ```
2. **Confirm gateway health independently of the observability stack** — this is the actual H4
   check:
   ```
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
   curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
     -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
     --data-binary @/home/user/serving-contracts/examples/api/chat-completion-request.json \
     -o /dev/null -w '%{http_code}\n'
   ```
   Expect unaffected 200s throughout the observability outage.
3. Check gateway logs for OTLP export errors — expected and benign during a Collector outage
   (connection-refused warnings), and these log lines should **not** correlate with any change in
   request-level HTTP status codes. If they do correlate, see Escalation below.

## Mitigation / Recovery

1. Restart the failed component(s):
   ```
   docker compose up -d otel-collector prometheus tempo grafana
   ```
   Kubernetes equivalent: `kubectl rollout restart deployment/<name> -n observability` per
   component, or a bulk restart if the whole namespace degraded together.
2. Restart order does not matter functionally for request-path safety (nothing in the gateway
   blocks on any of these), but Grafana's dashboards will not populate until Prometheus and Tempo
   are both back up and re-scraping/re-receiving — restart those first if dashboard visibility is
   the priority.
3. Once the stack is confirmed back up, re-run the full verification suite (this is itself a light
   check — 25 total HTTP requests plus scrape/exemplar queries, not a load test):
   ```
   scripts/verify-observability.sh
   ```

## Verification

- Prometheus scrape targets return to `health: up` for every job.
- An exemplar on `inference_ttft_seconds_bucket` resolves to a real trace in Tempo carrying the
  full expected span sequence (`recv → queue.wait → upstream.connect → ttft → stream.relay →
  settle`) — this repo's last real run of this exact check: `scripts/verify-observability.sh`,
  **16/16 passed** (`scripts/evidence/observability-20260711T233804Z/`).
- Golden dashboard panels render live data again through Grafana's Prometheus datasource proxy.

## Escalation

**If request-path success rate DOES drop when observability goes down, that is a serious finding**
— it means the "off the request path" architecture invariant (H4) has been violated somewhere
(e.g. trace export became synchronous/blocking on some code path, or a metrics-registry write
somehow started failing hard). Treat this as a P1 defect against infergate, not an inferops
observability-config issue: roll back to a known-good gateway digest immediately
(`rollback.md`) while investigating, rather than trying to fix it forward under live impact.

## Walkthrough

**Tabletop.** This session attempted a live walkthrough: baseline traffic was confirmed healthy
first (5/5 authenticated `POST /v1/chat/completions` returned 200, `/readyz` returned 200, against
the currently-running stack, 2026-07-12), then the plan was to stop
`otel-collector`/`prometheus`/`tempo`/`grafana` and re-check request success. That step was
declined by this session's own workload-safety guard — killing four containers this session did
not create, on a stack another agent could be concurrently using, is exactly the kind of shared-
infrastructure disruption this task's own instructions said to avoid ("do NOT drive heavy load on
the stack — another agent may be using it"). The decline was correct, not worked around.

The runbook above is therefore traced (not live-executed) against three real, checkable facts
instead: (a) `docs/observability.md` §1's explicit architecture statement that the stack is off
the request path, written at IO-T003 time; (b) the actual scrape topology in
`compose/prometheus/prometheus.yml` (Prometheus scrapes the gateway — pull, not push); (c) the
OTLP exporter wiring recorded in `docs/implementation-notes.md`'s IO-T003 log entry (async
batch export, confirmed via `git show`-level interface reading of the gateway's own telemetry
registry, `internal/telemetry/promreg.go`, at the time this repo's observability stack was built).

**This remains a real, open gap** (surfaced in `runbooks/README.md`): hypothesis H4 — "killing the
observability stack changes gateway request success rate by 0" — has not yet been independently,
live-verified end-to-end in this repo's evidence. A future session with exclusive access to the
stack (or a dedicated, deliberately-scheduled maintenance window) should complete it: stop the
four containers, drive a small number of requests, confirm 200s throughout, restart, re-run
`scripts/verify-observability.sh` to confirm full recovery.
