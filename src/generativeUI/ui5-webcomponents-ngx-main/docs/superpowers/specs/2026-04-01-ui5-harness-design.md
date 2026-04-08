# UI5 Harness Design

## Objective

Create a lightweight orchestration harness for `ui5-webcomponents-ngx-main` that makes live workspace operation deterministic, fast to verify, and safe to run repeatedly on developer machines and CI.

The harness is a workflow layer over existing scripts and services, not a replacement runtime.

## Scope

In scope:
- Orchestrate existing commands (`start:*`, `live:preflight`, `readiness:verify`, route checks).
- Provide one command for presenters/operators.
- Emit structured status reports for humans and automation.
- Enforce mode-based safety policies (workspace-safe vs dev-flex).

Out of scope:
- Replacing Nx, Cypress, MCP server, or OpenAI proxy internals.
- Rebuilding current health or diagnostics UIs.

## Primary UX

Single command:

`yarn harness:run --mode workspace-safe --profile local-live`

Expected behavior:
1. Validate environment and required ports.
2. Start or attach to required services.
3. Run preflight and page-level checks in parallel where safe.
4. Execute live verification suite.
5. Produce final verdict (`READY`, `DEGRADED`, `BLOCKED`) with actionable reasons.

## Architecture

## Components

- `scripts/harness/ui5-harness.mjs`
  - Main entrypoint, argument parsing, orchestration state machine.
- `scripts/harness/policies.mjs`
  - Mode policies (`workspace-safe`, `dev-flex`, `ci-strict`).
- `scripts/harness/checks/*.mjs`
  - Discrete checks:
  - `env-check.mjs`
  - `ports-check.mjs`
  - `services-check.mjs`
  - `routes-check.mjs`
  - `e2e-check.mjs`
- `scripts/harness/reporters/*.mjs`
  - `json-reporter.mjs` and `markdown-reporter.mjs`.

## State Machine

States:
- `INIT`
- `PRECHECK`
- `STARTUP`
- `VERIFY`
- `REPORT`
- `DONE`
- `FAILED`

Transitions:
- `INIT -> PRECHECK`: always.
- `PRECHECK -> STARTUP`: required checks pass (or permitted degraded mode).
- `STARTUP -> VERIFY`: required services healthy.
- `VERIFY -> REPORT`: checks complete (pass/fail/degraded).
- `REPORT -> DONE`: final status emitted.
- Any state -> `FAILED`: unrecoverable policy breach or infrastructure error.

## Policies

## Modes

- `workspace-safe`
  - No destructive actions.
  - Strict real-backend enforcement for workspace routes.
  - Fail fast on missing required dependencies.
- `dev-flex`
  - Allows degraded/no-auth local behavior with warnings.
  - Continues with partial checks.
- `ci-strict`
  - Deterministic non-interactive run.
  - Exit code must reflect final verdict.

## Verdict Rules

- `READY`: all required checks pass.
- `DEGRADED`: non-required checks fail but required checks pass.
- `BLOCKED`: any required check fails.

## Output Contract

## JSON report

Write `artifacts/harness/workspace-report.json`:

- `runId`
- `timestamp`
- `mode`
- `profile`
- `services` (status, latency, lastError)
- `routes` (status, latency, lastError)
- `checks` (name, required, status, evidence)
- `verdict`
- `exitCode`

## Markdown report

Write `artifacts/harness/workspace-report.md` with:
- headline verdict
- failed/blocked reasons
- top remediation actions

## Exit codes

- `0`: `READY`
- `10`: `DEGRADED`
- `20`: `BLOCKED`
- `30`: harness runtime failure

## Failure Taxonomy

- `CONFIG_MISSING`: required env values absent.
- `PORT_CONFLICT`: required port already occupied by unknown process.
- `SERVICE_UNHEALTHY`: health endpoint unreachable or unhealthy.
- `CONTRACT_MISMATCH`: API shape validation failed.
- `UI_ROUTE_BLOCKED`: route check failed due to backend readiness.
- `E2E_FAILURE`: Cypress/flow failure.
- `POLICY_VIOLATION`: attempted action blocked by selected mode.

Each failure must include:
- machine code
- short human message
- evidence snippet
- remediation hint

## Integration Plan (1-2 days)

1. Add `harness` entrypoint and argument parsing.
2. Wrap existing scripts as checks without changing their internals.
3. Add policy gate and verdict mapping.
4. Add JSON/Markdown reporters.
5. Add scripts:
   - `harness:run`
   - `harness:workspace`
   - `harness:ci`
6. Add unit tests for:
   - verdict mapping
   - policy gate behavior
   - report schema

## Acceptance Criteria

- One command yields a deterministic verdict in the local workspace environment.
- Operator sees clear reasons and next actions when not `READY`.
- CI can parse `workspace-report.json` and fail reliably on `BLOCKED`.
- Existing scripts remain backward compatible.

## Recommendation

Implement as a thin Node `.mjs` orchestration layer first (no Rust/Python dependency). This gives immediate operational value with minimal migration risk and reuses your current Nx + script surface directly.
