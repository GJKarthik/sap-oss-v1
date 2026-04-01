# UI5 Live Demo Presenter Cheat Sheet

Target app: `src/generativeUI/ui5-webcomponents-ngx-main`  
Audience: demo presenters, sales engineers, PMs  
Format: UI-only flow (no CLI during demo)

---

## Pre-Demo Rules

- Start on the `Readiness` page.
- Do not skip the `Check Now` step.
- Use `Start Demo` so the guided tour drives route order.
- If anything fails, return to `Readiness` and re-run checks.

---

## 6-8 Minute Script

### 0:00-0:45 — Readiness Gate

1. Open `Readiness`.
2. Click `Check Now`.
3. Confirm banner says `Demo Ready`.

Say:
- "These checks are live service checks from the UI, not mocked health flags."
- "We only start once all routes and dependencies are green."

### 0:45-1:00 — Start Guided Demo

1. Click `Start Demo`.
2. Confirm tour banner appears (`Demo Tour 1/4`).

Say:
- "Presenter mode enforces the route sequence and prevents missed steps."

### 1:00-2:15 — Step 1: Generative Renderer

1. Verify route opens without blocker banner.
2. Enter a prompt and click `Generate`.

Say:
- "This is the live schema-to-UI rendering path."
- "No timeout simulation path is used here."

### 2:15-3:30 — Step 2: Joule Chat

1. Click `Next Step` in tour banner.
2. Verify chat area is healthy (no error banner).

Say:
- "Joule route is live and guarded by route-level readiness."
- "If backend health drops, the UI surfaces real diagnostics."

### 3:30-4:45 — Step 3: Component Playground

1. Click `Next Step`.
2. Click `Refresh Live Catalog`.

Say:
- "This list comes from a live backend endpoint."
- "No static fixture fallback is shown as fake success."

### 4:45-6:00 — Step 4: MCP Integration

1. Click `Next Step`.
2. Confirm tools load.
3. Invoke a tool.

Say:
- "This is real MCP discovery and invocation over JSON-RPC."
- "You are seeing a live call/response cycle."

### 6:00-6:30 — Close Tour

1. Click `Next Step` again.
2. Confirm return to `Readiness`.
3. Confirm tour banner is gone.

Say:
- "The guided end-to-end flow completed successfully."

---

## Fast Recovery Playbook

### If a route is blocked

1. Go back to `Readiness`.
2. Click `Check Now`.
3. Click `Start Demo` again.

### If a service degrades mid-demo

1. Use `Service Health` panel to identify failing dependency.
2. State exact dependency and status.
3. Continue with remaining healthy routes or restart after recovery.

### If a route action stalls

1. Advance with `Next Step`.
2. Return later after health is green.

---

## One-Line Positioning

- "This demo is live-backend verified, UI-gated, and presenter-guided."

