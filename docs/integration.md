# Integration — inferops roles in I5 / I6 / I7

inferops owns I5, executes I7, and is the verification arm of I6. Evidence archival for the program lives in `inference-lab`; inferops produces the artifacts.

## I5 — Operational stack (inferops OWNS this milestone)

**Prerequisites:** I4 (or its recorded CPU fallback); infergate release IG-T016; IO-T002–T005.
**Pins in effect:** contracts bundle tag, infergate image digest, inferops release tag, dashboard/config bundle versions.

**Acceptance:** `inferops → infergate → vLLM → OTel/Prometheus/Grafana/Tempo` on the local cluster + GPU node:

- deployment from **released images only** (no source checkout — auditable);
- warm-up-aware readiness demonstrated;
- rolling update under load with **zero client-visible errors**;
- golden dashboards live;
- traces end-to-end (span sequence `recv → queue.wait → upstream.connect → ttft → stream.relay → settle` visible in Tempo).

**Failure handling:** probe/drain violations → fix manifests or the deployment contract (a contract change requires re-running I1 contract compatibility); observability gaps → dashboard/collector fix.
**Evidence:** manifests, smoke outputs, dashboard exports, rolling-update test log.
**CPU fallback:** if GPU gate G6 stays closed, a llama.cpp-backed I5 variant with a recorded deviation.

## I7 — Failure campaign (inferops owns EXECUTION; inference-lab owns evidence archival)

**Prerequisites:** I5; IO-T006/T007; the fault-scenario contract.
**Pins in effect:** frozen component set for the campaign (recorded in the campaign matrix header).

**Acceptance:**

- all 12 contract fault scenarios injected (GPU-dependent ones may run on the llama.cpp/mock path with a recorded deviation);
- per scenario: expected gateway semantics observed **or** deviation documented;
- client impact measured by inferbench for at least scenarios **1, 2, 5, 6, 12**;
- **≥2 postmortems** published in the standard format: timeline from real metrics, detection gap, root cause, mitigation, action items.

**Failure handling:** semantics mismatch → gateway defect or spec defect; fix, re-run scenario. Repeated flakiness → scenario marked unreliable with analysis.
**Evidence:** campaign matrix (12 rows: injected / observed / verdict), postmortems, client-impact measurements.

## I6 — Capacity feedback (verification arm; loop owned by inference-lab, recommendation by fleetlab)

inferops' role:

1. Apply the fleetlab capacity recommendation (replica count / config change per Contract 7) as a deployment change, so a repeated benchmark can measure the outcome.
2. Run the IO-T009 autoscaling experiments whose observed behavior is compared against fleetlab predictions.

A wrong prediction is a **result** to publish with error analysis, never a failure to hide. inferops never edits the recommendation or the analysis.

## Pins handling

- inferops manifests record: contract bundle tag, every image digest, engine version pins (vLLM minor + commit, llama.cpp commit — as of 2026-07, re-verify), model checkpoint revision + quantization + tokenizer, driver/CUDA per GPU node.
- The machine-readable pins matrix lives in `inference-lab`; the flow on any infergate release is: **digest bump in inferops → I5-level smoke green → pins file advances.** Never the reverse order.
- Dashboard/collector configs are versioned as inferops git tags so inference-lab can pin the exact operational configuration used for any archived evidence.
- Campaign runs freeze the full component set; the matrix records which pins were in effect (Definition-of-Done item 5: matrix archived in inference-lab **with the pins**).
