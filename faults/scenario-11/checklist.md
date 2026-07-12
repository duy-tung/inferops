# Scenario 11 — Observation checklist

- [x] `scripts/warmup-readiness-test.sh` exists and is re-runnable (IO-T004).
- [x] Fresh re-run for this campaign: 5/5 passed.
- [x] `/healthz` observed failing repeatedly before the backend came up, within the simulated
      startup budget.
- [x] `inference_backend_healthy` stayed 0 through warm-up, flipped to 1 exactly once.
- [x] A request during warm-up got a typed, non-2xx, non-hanging response.
- [x] A request after warm-up succeeded normally.
- [x] Container `RestartCount` stayed 0 (delay, not crash-restart loop).
- [x] Verdict recorded, citing both the IO-T004 evidence and this campaign's re-confirmation;
      campaign-matrix row written.
