# Generative UI 9/10 Tracker

Last updated: 2026-03-20
Status: Day 1 complete

This tracker covers the three target repos:

- `ui5-webcomponents-ngx-main`
- `sap-sac-webcomponents-ngx`
- `data-cleaning-copilot-main`

## Day 1 Outputs

- [x] Freeze the scoring rubric for what counts as `9/10` generative UI
- [x] Capture baseline scores for all three repos
- [x] Write the initial threat model
- [x] Define top user journeys for each repo

## Frozen 9/10 Rubric

Use the same rubric for all three repos. Scores are `0-10` per category.

| Category | Weight | What `9/10` looks like |
| --- | ---: | --- |
| Schema and runtime fidelity | 20% | Agent emits structured UI that renders correctly, updates incrementally, and survives reconnects and replays |
| Streaming and state sync | 15% | UI changes stream progressively with stable ordering, resumability, and clean reconciliation with live app state |
| Action execution and governance | 20% | Tool calls are typed, reviewable, approval-aware, reversible where needed, and visible to the user |
| Security and isolation | 20% | Hostile schemas, bindings, prompts, and tool payloads are blocked; dangerous execution paths are sandboxed |
| User trust and operator UX | 10% | Provenance, risk labels, confirmations, errors, retries, and rollback paths are visible and understandable |
| Workflow usefulness | 10% | Generated UI materially improves task completion instead of acting as chat chrome around existing flows |
| Testing and evaluation | 5% | Replay, adversarial, recovery, and journey tests exist and are used as release gates |

## Baseline Scores

| Repo | Baseline | Why it is not 9/10 yet |
| --- | ---: | --- |
| `ui5-webcomponents-ngx-main` | 7.5/10 | Strongest architecture, but binding sanitization, approval timing, audit wiring, and lifecycle cleanup are not complete |
| `sap-sac-webcomponents-ngx` | 6.0/10 | Promising domain UI, but action handling is partially stubbed, governance is light, and generated surfaces are too narrow |
| `data-cleaning-copilot-main` | 4.0/10 | Useful AI app, but still mostly chat plus panels, with dangerous code execution defaults and weak GenUI runtime behavior |

## Initial Threat Model

### Cross-cutting threats

| Threat | Description | Current concern |
| --- | --- | --- |
| Malicious schema injection | Agent emits unsafe component trees, props, bindings, or events | Highest in `ui5-webcomponents-ngx-main` |
| Blind action approval | User approves actions without complete arguments or impact summary | Highest in `ui5-webcomponents-ngx-main` and `sap-sac-webcomponents-ngx` |
| Tool abuse | Agent invokes powerful frontend or backend tools without proper confirmation | Present in all three repos |
| State drift | Generated state and live application state diverge after partial updates or reconnects | Highest in `sap-sac-webcomponents-ngx` |
| Prompt injection into execution | Model-generated code or tool args escape intended boundaries | Highest in `data-cleaning-copilot-main` |
| Missing audit trail | Runtime claims trust and governance but does not record the real action flow | Highest in `ui5-webcomponents-ngx-main` |
| Memory and lifecycle leaks | Dynamic component creation leaves listeners or component refs behind | Highest in `ui5-webcomponents-ngx-main` |

### Repo-specific threat focus

#### `ui5-webcomponents-ngx-main`

- Unsafe bound values reaching DOM properties through runtime bindings
- Action approvals created before full tool arguments are available
- Dynamic component refs created but not destroyed on removal
- Audit layer defined but not fully connected to governance outcomes

#### `sap-sac-webcomponents-ngx`

- Tool calls that mutate SAC state without strong review or rollback preview
- SSE event corruption or mismatch between tool call and tool result
- Drift between AG-UI state and actual SAC datasource state
- Narrow generated UI surface causing users to fall back to opaque chat

#### `data-cleaning-copilot-main`

- In-process execution of model-generated code
- Chat-only API preventing structured, reviewable task surfaces
- Low visibility into execution approval, provenance, and rollback
- Frontend locked into static panels instead of generated workflow UIs

## Top User Journeys

### `ui5-webcomponents-ngx-main`

1. Agent streams a multi-step business UI from a prompt and the UI renders progressively without reload.
2. Agent proposes a risky tool action and the user reviews exact arguments, impact, and risk before approving.
3. A streamed session disconnects and reconnects without losing the current run or UI state.
4. A generated UI is replayed from event logs for debugging or compliance review.

### `sap-sac-webcomponents-ngx`

1. User asks for a chart, the widget generates the right view, and live SAC data appears immediately.
2. User asks to change filters, chart type, or drill path and sees the UI update with clear state feedback.
3. User asks for a planning or data action and receives a concrete review step before execution.
4. Widget recovers from token refresh or backend reconnect without breaking the analyst workflow.

### `data-cleaning-copilot-main`

1. User asks to inspect a data quality problem and gets a generated analysis workspace, not only a text reply.
2. Agent generates candidate checks and the user reviews them in structured diff and approval surfaces.
3. User approves execution and sees progress, results, failures, and provenance in generated workflow UIs.
4. User revisits a prior run and understands what was generated, executed, rejected, and rolled back.

## 30-Day Checklist

### Score checkpoints

- [x] Day 1: Baseline scores captured for all three repos
- [ ] Day 10: `ui5-webcomponents-ngx-main` rescored
- [ ] Day 18: `sap-sac-webcomponents-ngx` rescored
- [ ] Day 28: `data-cleaning-copilot-main` rescored
- [ ] Day 30: Final portfolio scoring completed

### Days 1-10: `ui5-webcomponents-ngx-main`

- [x] Day 1: Freeze 9/10 rubric, baseline score, threat model, and top user journeys
- [ ] Day 2: Sanitize bound values in the dynamic renderer
- [ ] Day 3: Render only sanitized schema output from validation
- [ ] Day 4: Move governance approval to full tool-arguments stage
- [ ] Day 5: Wire audit logging to confirmations, rejections, and tool lifecycle
- [ ] Day 6: Fix dynamic Angular component lifecycle leaks and cleanup
- [ ] Day 7: Add patch updates, undo/redo, and replayable session logs
- [ ] Day 8: Add operator review UI with diffs, risk labels, and affected scope
- [ ] Day 9: Add red-team, reconnect, and large-session tests
- [ ] Day 10: Polish demos, rerun tests, and rescore to target `>= 8.5/10`

### Days 11-18: `sap-sac-webcomponents-ngx`

- [ ] Day 11: Freeze SAC-specific rubric, baseline score, and top 5 GenUI workflows
- [ ] Day 12: Harden SSE parsing, event validation, and tool-result correlation
- [ ] Day 13: Replace stub tool handlers with real SAC operations
- [ ] Day 14: Add confirmations and rollback previews for risky planning actions
- [ ] Day 15: Expand generated surfaces beyond chart, table, and KPI
- [ ] Day 16: Fix state-sync drift between agent state and live SAC state
- [ ] Day 17: Add widget harness coverage for auth refresh, reconnect, and action loops
- [ ] Day 18: Polish UX, rerun tests, and rescore to target `>= 8.5/10`

### Days 19-28: `data-cleaning-copilot-main`

- [ ] Day 19: Freeze rubric, workflow map, risk model, and baseline score
- [ ] Day 20: Make subprocess sandbox the default execution path for generated code
- [ ] Day 21: Add streaming runtime API for agent state, events, and approvals
- [ ] Day 22: Define UI schema contract for generated workflow surfaces
- [ ] Day 23: Build generated schema explorer and profiling surfaces
- [ ] Day 24: Build generated check-review and code-diff approval surfaces
- [ ] Day 25: Add execution approval, rollback, and provenance panels
- [ ] Day 26: Add history, retry, failure diagnosis, and progress views
- [ ] Day 27: Add prompt-injection, sandbox, and policy-gate tests
- [ ] Day 28: Polish workflows, rerun tests, and rescore to target `>= 8.0/10`

### Days 29-30: Final hardening

- [ ] Day 29: Run cross-repo red-team, replay, performance, and usability review
- [ ] Day 30: Final scoring, release notes, open-risk list, and next backlog

## Exit Criteria

- [ ] `ui5-webcomponents-ngx-main` has no open high-severity security or governance gaps
- [ ] `sap-sac-webcomponents-ngx` supports trustworthy generated analytics workflows end to end
- [ ] `data-cleaning-copilot-main` is a generated workflow product, not just a chat UI
- [ ] All three repos pass replay, recovery, and hostile-input tests
- [ ] All three repos reach `9/10` or have a signed-off shortfall list with exact blockers
