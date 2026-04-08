# UI5 Workspace Operator Guide

Target app: `src/generativeUI/ui5-webcomponents-ngx-main`  
Audience: workspace operators, sales engineers, PMs  
Format: UI-only flow (no CLI during the walkthrough)

---

## Pre-Launch Rules

- Start on the `Readiness` page.
- Do not skip the `Check Now` step.
- Use `Open Learn Path` only after all checks are green.
- If anything fails, return to `Readiness` and re-run checks.

---

## 6-8 Minute Walkthrough

### 0:00-0:45 — Readiness Gate

1. Open `Readiness`.
2. Click `Check Now`.
3. Confirm banner says `Workspace Ready`.

Say:
- "These are live service checks from the product UI, not mocked status flags."
- "We only move forward once routes and dependencies are green."

### 0:45-1:00 — Open Learn Path

1. Click `Open Learn Path`.
2. Confirm the learn path banner appears (`Learn Path 1/4`).

Say:
- "The learn path keeps the journey structured without exposing operator-only controls."

### 1:00-2:15 — Step 1: Generative Renderer

1. Verify the route opens without a blocker banner.
2. Enter a prompt and click `Generate`.

Say:
- "This is the live schema-to-UI rendering path."
- "The result is generated from real runtime services, not a staged fallback."

### 2:15-3:30 — Step 2: Joule Workspace

1. Click `Next Step` in the learn path banner.
2. Verify the chat area is healthy.

Say:
- "Joule is route-guarded by readiness and surfaces real diagnostics when dependencies degrade."

### 3:30-4:45 — Step 3: Model Catalog

1. Click `Next Step`.
2. Click `Refresh Live Catalog`.

Say:
- "This catalog is sourced from a live backend endpoint."
- "The product does not fake success with static fixtures."

### 4:45-6:00 — Step 4: MCP Tools

1. Click `Next Step`.
2. Confirm tools load.
3. Invoke a tool.

Say:
- "This is real MCP discovery and invocation over JSON-RPC."
- "You are seeing a live call-and-response cycle."

### 6:00-6:30 — Close Learn Path

1. Click `Next Step` again.
2. Confirm return to `Readiness`.
3. Confirm the learn path banner is gone.

Say:
- "The end-to-end workspace journey completed successfully."

---

## Fast Recovery Playbook

### If a route is blocked

1. Return to `Readiness`.
2. Click `Check Now`.
3. Click `Open Learn Path` again after the workspace is healthy.

### If a service degrades mid-session

1. Use the `Service Health` panel to identify the failing dependency.
2. State the exact dependency and status.
3. Continue with remaining healthy routes or restart after recovery.

### If a route action stalls

1. Advance with `Next Step`.
2. Return later after readiness is green again.

---

## One-Line Positioning

- "This workspace is live-backend verified, readiness-aware, and operator-guided."
