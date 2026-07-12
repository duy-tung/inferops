# Scenario 01 — Observation checklist

- [ ] `docker ps` confirms `inferops-mock-faults` and `inferops-gateway-faults` are up before
      injection.
- [ ] `inference_backend_healthy{backend="mock-faults"}` reads 1 before the kill.
- [ ] Background inferbench run started (streaming, fault-chat-short.json, rate 4).
- [ ] `docker kill -s SIGKILL inferops-mock-faults` issued, timestamp recorded.
- [ ] `inference_backend_healthy{backend="mock-faults"}` transitions to 0 within ~1s of the kill
      (poll interval 200ms + probe timeout).
- [ ] `inference_retries_total{stage="pre_first_token"}` increases after the kill; no other stage
      value appears anywhere in `/metrics`.
- [ ] `inference_requests_total{...,error_class="upstream_error"}` increases for requests that hit
      the dead backend.
- [ ] mock-faults restarted; `inference_backend_healthy{backend="mock-faults"}` returns to 1.
- [ ] Requests scheduled after recovery succeed (HTTP 200 / clean SSE `[DONE]`).
- [ ] inferbench `events.jsonl`: no event shows more output tokens than its own request's
      `max_completion_tokens` (no duplicated output); every `status=error` event during the outage
      carries `error_class` in {`upstream_error`,`upstream_timeout`} (never untyped/`internal`).
- [ ] inferbench run summary line captured (`sent`/`ok`/`errors`/`shed` counts) as the client-impact
      number.
- [ ] Verdict recorded in `verdict.md`; campaign-matrix row written.
