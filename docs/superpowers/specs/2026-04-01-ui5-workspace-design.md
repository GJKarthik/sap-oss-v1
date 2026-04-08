# UI5 Live Demo Design

**Date:** 2026-04-01  
**Target:** `src/generativeUI/ui5-webcomponents-ngx-main`  
**Scope:** Real code and real integrations only (no mocks, no fallback fixtures)

## Goal

Deliver a real live working demo centered on `ui5-webcomponents-ngx-main`, covering:

1. Generative UI renderer
2. Joule-style chat UI
3. Component playground
4. MCP-integrated flow

The work proceeds feature-by-feature for depth and production-like quality.

## Chosen Approach

The selected approach is **Feature-by-Feature Deep Build**:

- Fully complete one feature stream before starting the next.
- Keep all integrations real from day one.
- Converge all streams into one demo shell by the end.

Build order:

1. Renderer
2. Joule chat
3. Component playground
4. MCP flow

## Architecture

Create one demo host app experience with four first-class routes in `ui5-webcomponents-ngx-main`, executed sequentially in implementation order.

Each route includes:

- A dedicated page container
- A dedicated service layer for backend calls
- Route-level readiness checks with explicit blocking diagnostics

Shared platform concerns:

- Shared auth/token configuration
- Shared API client primitives (timeouts, retries, error mapping)
- Shared telemetry hooks (live request status)
- Shared demo health panel for upstream dependency checks

## Real Data Flow Rules (No Fake Paths)

1. Every user action must call a real backend or real MCP endpoint.
2. No mocked adapters or in-memory demo fixtures in demo routes.
3. If dependencies are unavailable, show blocking diagnostics, not placeholder content.
4. Validate responses at runtime and fail visibly on schema mismatch.
5. Stamp each request with correlation IDs and surface them in UI.
6. Expose backend failure details (status, body summary, latency, endpoint).

## Error Handling and Reliability

- Fail fast during app boot when mandatory upstreams are down.
- Disable route actions when preconditions are not met.
- Provide retry controls and clear operator actions.
- Ensure route-level failures are isolated and do not crash the full shell.

## Testing and Acceptance Gates

Each stream must pass all gates before moving to the next stream:

1. **Feature-complete gate:** route and core actions function against real services.
2. **Runtime proof gate:** real trace data appears in UI (status, latency, correlation ID).
3. **Failure-proof gate:** deterministic, actionable error states for upstream failures.
4. **E2E gate:** real browser test flow for the stream passes.
5. **Demo readiness gate:** preflight script validates env vars, endpoint health, and auth viability.

Global done criteria:

- All four streams pass real E2E flows in sequence.
- Unified shell navigation is stable.
- No mocked data paths remain in production/demo route code.

## Out of Scope

- Mock/fake backend fallback modes for demo routes
- Cosmetic-only UI changes not tied to live behavior
- Cross-repo expansion outside selected target unless required for integration

