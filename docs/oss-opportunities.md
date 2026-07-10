# OSS opportunities — inferops

OSS activity is logged in `inference-lab` (IL-T010–T012); this file tracks what this repo's work can feed upstream. All submissions require user review before posting. Avoid: scheduler rewrites, architecture replacements, unverified performance claims.

## Primary target: Gateway API Inference Extension (GAIE) / llm-d

GAIE is the program's primary OSS target: Go, kind-testable, and exactly the gateway/routing boundary this portfolio works at. Opportunities inferops is positioned to discover while building the reference stack:

- **Examples/docs improvements:** probe configurations for slow-warming model servers, kind-based test setups, GPU-node examples — the same artifacts IO-T002/T004/T005 produce, generalized.
- **Migration caveat:** the ecosystem is migrating toward llm-d with an `InferenceModel` → `InferenceObjective` rename (source-reported as of 2026-07 — **re-verify before engaging**; check which repo accepts contributions and where examples now live).

## Reference configurations as publishable artifacts

Reproducible K8s inference-ops configurations qualify as the OSS track's "public benchmark or design artifact" in their own right:

1. **Warm-up-aware readiness pattern for model servers** — startupProbe window sizing, honest readiness, liveness-never-kills-warming semantics (IO-T004/T005 output).
2. **Drain-correct rolling-update recipe** — preStop drain + grace-period arithmetic + PDB + zero-client-error verification script (IO-T004 output).
3. **Dashboards keyed to a published metrics vocabulary** — the golden dashboard + exemplar wiring as a worked example of low-cardinality LLM-serving observability (IO-T003 output).

## Working rules

- **Artifact-or-drop:** an OSS thread that produces no concrete artifact after two sessions is dropped (program study-track rule).
- Discoveries (bugs, doc gaps, example gaps) found during IO tasks are noted here with a date and the task that surfaced them, then triaged into inference-lab's OSS log.
- Contributions are always grounded in evidence this repo actually produced (a config we ran, a failure we reproduced) — never speculative advice.

## Discovery log

*(empty — populated as IO tasks surface upstream gaps)*

| Date | Found during | Upstream | Observation | Status |
|---|---|---|---|---|
