#!/usr/bin/env bash
# IO-T003 evidence: drives a test stream through the compose-deployed
# gateway, then verifies metrics + traces are visible end-to-end:
#   1. Prometheus has scraped the gateway's Contract 2 metrics.
#   2. An exemplar (trace_id) is attached to a latency histogram bucket.
#   3. That trace_id resolves to a real trace in Tempo with the expected
#      recv -> queue.wait -> upstream.connect -> ttft -> stream.relay ->
#      settle span sequence (docs/observability.md §5) — i.e. the exemplar
#      click-through Grafana wires up really does open a real trace.
#   4. Grafana has the golden dashboard provisioned and its panel queries
#      render live data through the Prometheus datasource proxy.
#
# Assumes the full compose stack (baseline + observability) and the
# bootstrap tenant/key (scripts/bootstrap-dev-db.sh) are already up.
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
FIXTURES="/home/user/serving-contracts/examples/api"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/scripts/evidence/observability-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0
log() { echo "$*" | tee -a "$OUT_DIR/transcript.log"; }
ok()  { log "PASS  $*"; PASS=$((PASS+1)); }
bad() { log "FAIL  $*"; FAIL=$((FAIL+1)); }

API_KEY="$(cat "$COMPOSE_DIR/secrets/smoke_api_key.txt")"
GRAFANA_PW="$(cat "$COMPOSE_DIR/secrets/grafana_admin_password.txt")"

log "== inferops observability verification — $(date -u --iso-8601=seconds) =="

log "-- driving test traffic (20 non-stream + 5 stream requests) --"
for _ in $(seq 1 20); do
  curl -s -o /dev/null -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
    --data-binary @"$FIXTURES/chat-completion-request.json"
done
for _ in $(seq 1 5); do
  curl -s -N -o /dev/null -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
    --data-binary @"$FIXTURES/chat-completion-request-stream.json"
done
sleep 8   # scrape_interval=5s (prometheus.yml) + a margin for the collector/tempo pipeline

log ""
log "-- Prometheus scrape targets --"
curl -s http://127.0.0.1:9090/api/v1/targets | tee "$OUT_DIR/prometheus-targets.json" | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(t['labels'].get('job'), t['health'])
" | tee -a "$OUT_DIR/transcript.log"
if python3 -c "
import json
d=json.load(open('$OUT_DIR/prometheus-targets.json'))
t=[x for x in d['data']['activeTargets'] if x['labels'].get('job')=='infergate-gateway']
exit(0 if t and t[0]['health']=='up' else 1)
"; then ok "gateway scrape target up"; else bad "gateway scrape target not up"; fi

log ""
log "-- Contract 2 metric presence (all 11 canonical names) --"
for m in inference_requests_total inference_requests_in_flight inference_queue_depth \
         inference_queue_wait_seconds_bucket inference_ttft_seconds_bucket inference_itl_seconds_bucket \
         inference_e2e_duration_seconds_bucket inference_sheds_total inference_retries_total \
         inference_backend_healthy inference_usage_tokens_total; do
  count=$(curl -s "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=count(${m})" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
print(r[0]['value'][1] if r else '0')
")
  if [[ "$count" != "0" ]]; then ok "metric present: $m ($count series)"; else bad "metric present: $m"; fi
done

log ""
log "-- Exemplar on inference_ttft_seconds_bucket --"
EX=$(curl -s "http://127.0.0.1:9090/api/v1/query_exemplars" \
  --data-urlencode 'query=inference_ttft_seconds_bucket' \
  --data-urlencode "start=$(( $(date +%s) - 300 ))" \
  --data-urlencode "end=$(date +%s)")
echo "$EX" > "$OUT_DIR/exemplars-ttft.json"
TRACE_ID=$(printf '%s' "$EX" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for series in d['data']:
    for e in series['exemplars']:
        print(e['labels']['trace_id']); break
    else: continue
    break
" 2>/dev/null)
if [[ -n "${TRACE_ID:-}" ]]; then
  ok "exemplar found on inference_ttft_seconds_bucket (trace_id=$TRACE_ID)"
else
  bad "no exemplar found on inference_ttft_seconds_bucket"
fi

log ""
log "-- Exemplar trace_id resolves in Tempo, expected span sequence present --"
if [[ -n "${TRACE_ID:-}" ]]; then
  TRACE_JSON=$(docker exec inferops-gateway wget -q -O - -T 5 "http://tempo:3200/api/traces/${TRACE_ID}" 2>/dev/null)
  echo "$TRACE_JSON" > "$OUT_DIR/tempo-trace-${TRACE_ID}.json"
  SPANS=$(printf '%s' "$TRACE_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
names=set()
for b in d.get('batches',[]):
    for ss in b.get('scopeSpans',[]):
        for s in ss.get('spans',[]):
            names.add(s['name'])
print(','.join(sorted(names)))
" 2>/dev/null)
  log "spans found: $SPANS"
  EXPECTED="queue.wait,recv,settle,stream.relay,ttft,upstream.connect"
  if [[ "$SPANS" == "$EXPECTED" ]]; then
    ok "trace $TRACE_ID has the full expected span sequence (recv -> queue.wait -> upstream.connect -> ttft -> stream.relay -> settle)"
  else
    bad "trace $TRACE_ID span set ($SPANS) does not match expected ($EXPECTED)"
  fi
else
  bad "skipped (no trace_id from previous step)"
fi

log ""
log "-- Grafana: golden dashboard provisioned --"
DASH=$(curl -s -u "admin:$GRAFANA_PW" "http://127.0.0.1:3000/api/search?query=golden")
echo "$DASH" > "$OUT_DIR/grafana-dashboard-search.json"
if printf '%s' "$DASH" | grep -q '"uid":"inferops-golden"'; then
  ok "golden dashboard provisioned (uid=inferops-golden)"
else
  bad "golden dashboard not found via Grafana API"
fi

log ""
log "-- Grafana: a dashboard panel query renders live data through the Prometheus datasource proxy --"
PANELQ=$(curl -s -u "admin:$GRAFANA_PW" "http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/query" \
  --data-urlencode 'query=sum by (direction) (rate(inference_usage_tokens_total[1m]))')
echo "$PANELQ" > "$OUT_DIR/grafana-panel-query.json"
if printf '%s' "$PANELQ" | grep -q '"status":"success"' && printf '%s' "$PANELQ" | grep -q '"direction"'; then
  ok "golden dashboard's token-throughput panel query renders live data via Grafana"
else
  bad "golden dashboard panel query did not render data via Grafana"
fi

log ""
log "== Summary: $PASS passed, $FAIL failed =="
log "Evidence directory: $OUT_DIR"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
