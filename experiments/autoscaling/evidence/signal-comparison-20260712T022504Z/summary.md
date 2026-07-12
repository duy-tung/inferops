# H-AS-1 signal-comparison — per-phase summary (measured, not simulated)

Workload start (UTC): `2026-07-12T02:25:08.905111+00:00`. True knee onset (phase 3 start): elapsed 90s.

| Phase | Offered rps (planned) | Offered rps (client-observed) | Goodput rps (client-observed) | Shed frac | queue_depth mean/max | in_flight mean/max | token_rate_out mean | cpu_pct_inferops-gateway-signals mean/max | cpu_pct_inferops-mock-signals mean/max |
|---|---|---|---|---|---|---|---|---|---|
| 1 (quiet (~24% of measured capacity)) | 8 | 8.2 | 8.2 | 0.0 | 0.0/0.0 | 1.043/3.0 | 55.967 | 3.086/5.44 | 2.817/5.48 |
| 2 (approaching (~60%)) | 20 | 20.756 | 20.578 | 0.0086 | 0.0/0.0 | 2.955/6.0 | 153.949 | 7.489/9.76 | 6.667/8.22 |
| 3 (at ~1x (IB-T010 E2 baseline rate)) | 37.8072 | 39.25 | 33.583 | 0.1444 | 0.967/3.0 | 5.467/6.0 | 259.556 | 10.346/14.68 | 7.999/9.91 |
| 4 (5x severe overload (IB-T010 E2 overload rate)) | 189.0362 | 181.0 | 37.4 | 0.7934 | 2.714/3.0 | 6.0/6.0 | 296.968 | 14.224/16.67 | 7.011/8.55 |
| 5 (cool-down (scale-in window)) | 8 | 8.067 | 8.067 | 0.0 | 0.13/3.0 | 1.435/6.0 | 92.986 | 3.088/5.34 | 2.653/4.59 |

## Detection (fleetlab ADR-0003 rule: calib-window mean+3*std threshold, 5s debounce, 0.7x/5s clear)

| Signal | calib threshold | first-fire elapsed_s | lag vs knee onset (90s) | fired before knee (false/early)? | episodes |
|---|---|---|---|---|---|
| queue_depth | 0.0 | 154.42 | 64.42 | False | [(154.42, 172.5)] |
| requests_in_flight | 3.9071 | 96.1 | 6.1 | False | [(96.1, 178.53)] |
| token_rate_output_per_s | 111.9812 | 55.88 | -34.12 | True | [(55.88, 180.54)] |
| cpu_pct_inferops-gateway-signals | 5.9237 | 51.86 | -38.14 | True | [(51.86, 170.49)] |
| cpu_pct_inferops-mock-signals | 5.9238 | 51.86 | -38.14 | True | [(51.86, 170.49)] |
