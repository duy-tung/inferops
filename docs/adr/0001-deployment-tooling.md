# ADR-0001 — Deployment tooling: Kustomize + raw manifests

- **Status:** Proposed (mandatory human-review point before IO-T002)
- **Date:** 2026-07-10
- **Deciders:** inferops maintainer (program review)

## Context

inferops must pick the smallest combination out of {Helm, Kustomize, raw manifests, optional Terraform, Argo CD} that the actual requirements justify. The requirements are narrow and known:

- **One local CPU cluster** (kind) plus **one documented GPU-node profile** — not a fleet, not multi-env promotion.
- **Single operator**, no team-scale release coordination, no continuous delivery to shared environments.
- Manifests must be **derivable from the Contract 5 deployment descriptor** and **auditable**: reviewers must be able to diff exactly what is applied, and verify digest pinning (released-images-only rule) at a glance.
- The real variation axes are few and structural, not textual: CPU vs GPU overlay for engine workloads, image-digest bumps, replica-count changes for autoscaling experiments, ConfigMap versioning for the scenario-8 config-rollout mechanics.
- The repo's headline risk is **R7 — Kubernetes time sink**: every tool admitted is surface that must earn its evidence value.

## Decision

**Raw YAML manifests as the source of truth, composed with Kustomize (the `kustomize` built into `kubectl`).** Nothing else in the baseline.

- **Raw manifests** — because auditability is a first-order requirement. A reviewer checking the released-images-only rule, probe semantics against the deployment contract, or the grace-period arithmetic reads plain YAML with no template indirection. `kubectl kustomize` output is the exact applied state.
- **Kustomize** — because the variation we actually have is exactly what Kustomize does natively without a templating language: bases + overlays (local CPU cluster vs GPU-node profile), `images:` digest pinning in one reviewable place, replica patches for experiments, `configMapGenerator` with content-hash suffixes — which directly implements the immutable-ConfigMap-versioning mechanics that the config-rollout procedure (IO-T010, fault scenario 8) needs. It ships inside `kubectl`, adding zero new tools to CI.

## Tools explicitly not admitted (and their re-entry conditions)

- **Helm — not admitted.** No proven templating need exists: no third parties consume our manifests with parameter matrices, no multi-env value sets, no conditional resource generation. Helm adds a template layer between the reviewer and the applied YAML, which works against the audit requirements. **Re-entry condition:** a concrete, recorded templating need that Kustomize overlays/patches demonstrably cannot express — recorded in a new ADR *before* adoption. (Third-party charts for the observability stack are not, by themselves, such a need: upstream-rendered manifests or upstream static YAML are used instead; if a specific component proves unmaintainable that way, that is the concrete evidence a new ADR would cite.)
- **Argo CD — not admitted.** GitOps controllers solve drift detection and multi-actor sync on long-lived shared clusters. This program has a single operator and clusters that are created and destroyed by scripts; `kubectl apply -k` from a reviewed commit gives the same git-as-source-of-truth property with none of the controller surface. Evidence value: zero. **Re-entry condition:** a long-lived shared cluster with multiple actors — out of scope per `docs/non-goals.md`.
- **Terraform — not admitted.** Nothing is declaratively provisioned in the baseline: kind is created by a script in CI/locally, and the GPU node is a rented single machine governed by a documented profile + session scripts (hypothesis, auto-stop, teardown) whose entire point is being short-lived and reproducible from the doc. **Re-entry condition:** recurring multi-resource cloud provisioning whose manual/scripted form has demonstrably caused a recorded error.

## Consequences

**Positive**

- Smallest reviewable surface: one tool (`kubectl`), plain YAML diffs, digest pins visible in one place per overlay. Directly mitigates R7.
- Config-rollout mechanics (scenario 8) fall out of `configMapGenerator` hash-suffixed ConfigMaps + rollout, rather than needing extra machinery.
- CI needs no additional installs; `kustomize build` doubles as the manifest-lint step.

**Negative / accepted costs**

- Some repetition across overlays that Helm templating would compress — accepted; the repetition is small at this scale and cheaper than template indirection.
- Third-party observability components must be consumed as static upstream YAML or pre-rendered manifests, then patched — slightly more curation work, but keeps the applied state fully auditable.
- If the re-entry conditions trigger, adopting a new tool later costs a migration — accepted as unlikely at this scope and cheap at this repo size.

**Follow-ups**

- kind-vs-k3s is a separate, later ADR, to be written with CI evidence during IO-T002 (working assumption: kind — see `docs/implementation-notes.md` A-1).
- Possible later ADRs, each only on evidence: KEDA (if an autoscaling signal cannot be served by HPA + metrics adapter), chaos tooling (if `kubectl`-level injection proves insufficient for a scenario), SOPS/sealed-secrets (if secret distribution needs arise).

## Revisit policy

Revisit only on evidence, per the program deviation policy (`docs/implementation-notes.md` § Deviations). "It would be nicer with X" is not evidence; a recorded failure or a recorded concrete need is.
