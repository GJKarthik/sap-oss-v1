# Centralized Regulations Repository

Canonical governance rules now live under `src/regulations/mangle/`.

## Layout

- `rules.mg` — shared governance predicates and framework cross-links
- `frameworks/*.mg` — framework-specific controls (`MGF-Agentic-AI`, `AI-Agent-Index`, `GDPR`)
- `domains/*.mg` — domain overlays for finance and procurement use cases

## Governance semantics

- `governance_dimension(Field, Category)` classifies a field into one of four categories: accountability, transparency, fairness, or safety.
- `requires_dimension(Action, Dimension)` maps actions to the governance dimension they trigger.
- `implicates_dimension(Action, Dimension)` is the derived alias used by consumers that need impact evaluation.
- `subject_to_review(Action, Reason)` exposes the review reason produced by the triggered dimension or framework.

## Migration guide

1. Replace project-local includes with `include "../../../../regulations/mangle/rules.mg".` from `mangle/domain/agents.mg` in generativeUI projects.
2. Treat project-local `regulations/mangle/rules.mg` stubs as deprecated compatibility shims until remaining consumers migrate.
3. Add any project-specific governance facts in framework/domain overlays rather than copying `rules.mg` into individual projects.