# Scenario 05 — Observation checklist

- [ ] Fleet (mock-faults, gateway-faults-a/-b, haproxy-faults) up, both instances passing
      `/readyz` through the LB before injection.
- [ ] Background inferbench streaming population running against the LB endpoint.
- [ ] `docker kill -s SIGTERM inferops-gateway-faults-a` issued mid-run; timestamp recorded.
- [ ] gateway-faults-a's `/readyz` (direct) flips to non-200 promptly after the signal.
- [ ] haproxy's health check pulls gateway-faults-a out of rotation (`inter 500ms fall 1`).
- [ ] gateway-faults-a's container exits on its own (no forced kill needed).
- [ ] gateway-faults-b keeps serving new requests throughout.
- [ ] inferbench summary: 0 errors attributable to the termination window (`errors=0` or any
      non-zero count independently explained, never silently excused).
- [ ] Verdict recorded; campaign-matrix row written; IO-T004 evidence cited.
