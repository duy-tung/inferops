# Scenario 10 — Observation checklist

- [ ] `inference_backend_healthy{backend="mock-faults"}` reads 1 before the pause.
- [ ] `docker pause inferops-mock-faults` issued; requests sent every ~100ms afterward.
- [ ] `inference_backend_healthy` transitions to 0 within roughly 1s of the pause (poll 200ms +
      probe timeout 150ms).
- [ ] Requests during the stale window (before health flips) get a typed failure (never a hang —
      confirmed via a bounded per-request `curl -m` timeout).
- [ ] Requests after health flips to 0 get an immediate typed 503 `backend_unavailable` (no
      multi-second hang waiting to dial a frozen backend).
- [ ] `docker unpause inferops-mock-faults`; `inference_backend_healthy` returns to 1 within one
      poll interval.
- [ ] Requests after recovery succeed normally.
- [ ] Verdict recorded, including the reduced-form note; campaign-matrix row written.
