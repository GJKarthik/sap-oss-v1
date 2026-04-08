# UI5 Live Demo Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a real, end-to-end live demo in `ui5-webcomponents-ngx-main` with four production-like flows (Generative Renderer, Joule Chat, Component Playground, MCP Integration) using real backends only.

**Architecture:** Extend `apps/playground` into a single demo shell with dedicated feature routes and shared runtime health/diagnostics. Implement feature streams sequentially (deep build): renderer -> chat -> component playground -> MCP flow. Add route-level readiness guards, typed API clients, and real E2E verification for each stream.

**Tech Stack:** Angular 20, Nx, UI5 Web Components, existing `@ui5/genui-*` libs, MCP server (`mcp-server`), OpenAI server (`libs/openai-server`), Cypress E2E, Jest unit tests.

---

## File Structure (Planned Changes)

**Create**
- `apps/playground/src/app/core/live-demo-config.ts`
- `apps/playground/src/app/core/live-demo-health.service.ts`
- `apps/playground/src/app/core/request-trace.interceptor.ts`
- `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.ts`
- `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.html`
- `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.scss`
- `apps/playground/src/app/modules/component-playground/component-playground.module.ts`
- `apps/playground/src/app/modules/component-playground/component-playground-page.component.ts`
- `apps/playground/src/app/modules/component-playground/component-playground-page.component.html`
- `apps/playground/src/app/modules/component-playground/component-playground-page.component.scss`
- `apps/playground/src/app/modules/mcp/mcp.module.ts`
- `apps/playground/src/app/modules/mcp/mcp-page.component.ts`
- `apps/playground/src/app/modules/mcp/mcp-page.component.html`
- `apps/playground/src/app/modules/mcp/mcp-page.component.scss`
- `apps/playground/src/app/modules/generative/generative-runtime.service.ts`
- `apps/playground/src/app/modules/generative/generative-contracts.ts`
- `apps/playground-e2e/src/e2e/live-demo-renderer.cy.ts`
- `apps/playground-e2e/src/e2e/live-demo-chat.cy.ts`
- `apps/playground-e2e/src/e2e/live-demo-component-playground.cy.ts`
- `apps/playground-e2e/src/e2e/live-demo-mcp.cy.ts`
- `scripts/live-demo-preflight.mjs`

**Modify**
- `apps/playground/src/environments/environment.ts`
- `apps/playground/src/environments/environment.prod.ts`
- `apps/playground/src/app/app.module.ts`
- `apps/playground/src/app/app.component.html`
- `apps/playground/src/app/app.component.ts`
- `apps/playground/src/app/main.component.html`
- `apps/playground/src/app/main.component.ts`
- `apps/playground/src/app/modules/generative/generative-page.component.ts`
- `apps/playground/src/app/modules/generative/generative.module.ts`
- `apps/playground/src/app/modules/joule/joule-shell.component.ts`
- `apps/playground/src/app/modules/joule/joule-shell.component.html`
- `apps/playground-e2e/src/support/commands.ts`
- `apps/playground-e2e/src/support/e2e.ts`
- `apps/playground-e2e/cypress.config.ts`
- `package.json`
- `README.md`

**Test**
- `apps/playground/src/app/modules/generative/generative-page.component.spec.ts`
- `apps/playground/src/app/modules/joule/joule-shell.component.spec.ts`
- `apps/playground/src/app/core/live-demo-health.service.spec.ts`
- `apps/playground/src/app/modules/mcp/mcp-page.component.spec.ts`

---

## Chunk 1: Core Live-Demo Infrastructure

### Task 1: Add strict live-demo runtime config

**Files:**
- Create: `apps/playground/src/app/core/live-demo-config.ts`
- Modify: `apps/playground/src/environments/environment.ts`
- Modify: `apps/playground/src/environments/environment.prod.ts`
- Test: `apps/playground/src/app/core/live-demo-health.service.spec.ts`

- [ ] **Step 1: Write failing config test**
```ts
it('requires real service URLs in live mode', () => {
  expect(() => validateLiveConfig({ mcpBaseUrl: '' } as any)).toThrow();
});
```

- [ ] **Step 2: Run test to verify it fails**
Run: `yarn nx test playground --testPathPattern=live-demo-health.service.spec.ts`
Expected: FAIL with missing config validator.

- [ ] **Step 3: Implement live config + validator**
```ts
export interface LiveDemoConfig {
  agUiEndpoint: string;
  openAiBaseUrl: string;
  mcpBaseUrl: string;
  requireRealBackends: true;
}
```

- [ ] **Step 4: Run targeted test**
Run: `yarn nx test playground --testPathPattern=live-demo-health.service.spec.ts`
Expected: PASS for config validation.


### Task 2: Add shared health service + diagnostics model

**Files:**
- Create: `apps/playground/src/app/core/live-demo-health.service.ts`
- Test: `apps/playground/src/app/core/live-demo-health.service.spec.ts`

- [ ] **Step 1: Write failing service tests**
```ts
it('marks route blocked when required service is down', async () => {
  // arrange failing probe
  expect(result.blocking).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it fails**
Run: `yarn nx test playground --testPathPattern=live-demo-health.service.spec.ts`
Expected: FAIL on missing service implementation.

- [ ] **Step 3: Implement probe + route gating**
```ts
checkRouteReadiness(route: 'generative'|'joule'|'components'|'mcp'): Observable<RouteReadiness>;
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test playground --testPathPattern=live-demo-health.service.spec.ts`
Expected: PASS.


### Task 3: Add request tracing interceptor (correlation IDs)

**Files:**
- Create: `apps/playground/src/app/core/request-trace.interceptor.ts`
- Modify: `apps/playground/src/app/app.module.ts`

- [ ] **Step 1: Write failing interceptor test**
```ts
expect(req.headers.has('x-correlation-id')).toBe(true);
```

- [ ] **Step 2: Run test and confirm fail**
Run: `yarn nx test playground --testPathPattern=request-trace`
Expected: FAIL no interceptor wired.

- [ ] **Step 3: Implement interceptor + provider registration**
```ts
const requestId = crypto.randomUUID();
req = req.clone({ setHeaders: { 'x-correlation-id': requestId } });
```

- [ ] **Step 4: Re-run tests**
Run: `yarn nx test playground --testPathPattern=request-trace`
Expected: PASS.


### Task 4: Add reusable health panel component

**Files:**
- Create: `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.ts`
- Create: `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.html`
- Create: `apps/playground/src/app/shared/live-health-panel/live-health-panel.component.scss`
- Modify: `apps/playground/src/app/app.component.html`

- [ ] **Step 1: Write failing render test**
```ts
expect(screen.getByText(/Service Health/i)).toBeTruthy();
```

- [ ] **Step 2: Run test to verify fail**
Run: `yarn nx test playground --testPathPattern=live-health-panel`
Expected: FAIL component not found.

- [ ] **Step 3: Implement health panel**
```html
<ui5-message-strip [design]="blocking ? 'Negative' : 'Positive'">
  {{ summaryText }}
</ui5-message-strip>
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test playground --testPathPattern=live-health-panel`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/playground/src/app/core apps/playground/src/app/shared apps/playground/src/environments docs/superpowers/specs/2026-04-01-ui5-live-demo-design.md
git commit -m "feat(playground): add live backend health and request tracing foundation"
```

---

## Chunk 2: Deep Build 1 + 2 (Generative Renderer, Joule Chat)

### Task 5: Replace simulated generative flow with real runtime service

**Files:**
- Create: `apps/playground/src/app/modules/generative/generative-runtime.service.ts`
- Create: `apps/playground/src/app/modules/generative/generative-contracts.ts`
- Modify: `apps/playground/src/app/modules/generative/generative-page.component.ts`
- Test: `apps/playground/src/app/modules/generative/generative-page.component.spec.ts`

- [ ] **Step 1: Add failing spec for real API call behavior**
```ts
it('does not render fake schema when backend call fails', () => {
  expect(component.loading).toBe(false);
  expect(component.uiSchema).toBeNull();
});
```

- [ ] **Step 2: Run spec to fail**
Run: `yarn nx test playground --testPathPattern=generative-page.component.spec.ts`
Expected: FAIL (current setTimeout simulation path still present).

- [ ] **Step 3: Implement runtime service + remove setTimeout simulation**
```ts
this.runtime.generateSchema(prompt).subscribe({
  next: (schema) => this.uiSchema = schema,
  error: (err) => this.lastError = mapBackendError(err)
});
```

- [ ] **Step 4: Re-run generative tests**
Run: `yarn nx test playground --testPathPattern=generative-page.component.spec.ts`
Expected: PASS.


### Task 6: Add readiness gate + diagnostics to generative route

**Files:**
- Modify: `apps/playground/src/app/modules/generative/generative-page.component.ts`
- Modify: `apps/playground/src/app/modules/generative/generative.module.ts`

- [ ] **Step 1: Add failing spec for blocked route when service down**
```ts
expect(component.blockingReason).toContain('AG-UI');
```

- [ ] **Step 2: Run spec to confirm fail**
Run: `yarn nx test playground --testPathPattern=generative-page.component.spec.ts`
Expected: FAIL.

- [ ] **Step 3: Implement live readiness gate**
```ts
if (readiness.blocking) { this.blockingReason = readiness.message; return; }
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test playground --testPathPattern=generative-page.component.spec.ts`
Expected: PASS.


### Task 7: Harden Joule route for real streaming + explicit backend diagnostics

**Files:**
- Modify: `apps/playground/src/app/modules/joule/joule-shell.component.ts`
- Modify: `apps/playground/src/app/modules/joule/joule-shell.component.html`
- Test: `apps/playground/src/app/modules/joule/joule-shell.component.spec.ts`

- [ ] **Step 1: Add failing spec for backend-specific error output**
```ts
expect(fixture.nativeElement.textContent).toContain('AG-UI endpoint');
expect(fixture.nativeElement.textContent).toContain('x-correlation-id');
```

- [ ] **Step 2: Run Joule tests and confirm fail**
Run: `yarn nx test playground --testPathPattern=joule-shell.component.spec.ts`
Expected: FAIL.

- [ ] **Step 3: Implement typed error mapping and readiness checks**
```ts
this.connectionError = `AG-UI endpoint unavailable (${status}) [${correlationId}]`;
```

- [ ] **Step 4: Re-run Joule tests**
Run: `yarn nx test playground --testPathPattern=joule-shell.component.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/playground/src/app/modules/generative apps/playground/src/app/modules/joule apps/playground/src/app/core
git commit -m "feat(playground): switch generative and joule flows to strict live backend execution"
```

---

## Chunk 3: Deep Build 3 + 4 (Component Playground, MCP Flow)

### Task 8: Build live component playground route (real metadata source)

**Files:**
- Create: `apps/playground/src/app/modules/component-playground/component-playground.module.ts`
- Create: `apps/playground/src/app/modules/component-playground/component-playground-page.component.ts`
- Create: `apps/playground/src/app/modules/component-playground/component-playground-page.component.html`
- Create: `apps/playground/src/app/modules/component-playground/component-playground-page.component.scss`
- Modify: `apps/playground/src/app/app.module.ts`
- Modify: `apps/playground/src/app/app.component.html`
- Modify: `apps/playground/src/app/main.component.html`

- [ ] **Step 1: Add failing component route test**
```ts
expect(router.url).toBe('/components');
```

- [ ] **Step 2: Run tests to verify fail**
Run: `yarn nx test playground --testPathPattern=component-playground`
Expected: FAIL route/module missing.

- [ ] **Step 3: Implement route + live metadata fetch**
```ts
this.http.get<ComponentCatalog>(`${env.openAiBaseUrl}/v1/ui/components`).subscribe(...)
```

- [ ] **Step 4: Re-run tests**
Run: `yarn nx test playground --testPathPattern=component-playground`
Expected: PASS.


### Task 9: Build MCP route with real tool discovery + invoke

**Files:**
- Create: `apps/playground/src/app/modules/mcp/mcp.module.ts`
- Create: `apps/playground/src/app/modules/mcp/mcp-page.component.ts`
- Create: `apps/playground/src/app/modules/mcp/mcp-page.component.html`
- Create: `apps/playground/src/app/modules/mcp/mcp-page.component.scss`
- Modify: `apps/playground/src/app/app.module.ts`
- Modify: `apps/playground/src/app/app.component.html`
- Test: `apps/playground/src/app/modules/mcp/mcp-page.component.spec.ts`

- [ ] **Step 1: Add failing tests for list-tools and call-tool flows**
```ts
expect(component.tools.length).toBeGreaterThan(0);
expect(component.lastCallResult).toBeDefined();
```

- [ ] **Step 2: Run tests to fail**
Run: `yarn nx test playground --testPathPattern=mcp-page.component.spec.ts`
Expected: FAIL no MCP module/component.

- [ ] **Step 3: Implement JSON-RPC MCP client and invoke UI**
```ts
POST /mcp { "jsonrpc":"2.0","method":"tools/list","id":"..." }
POST /mcp { "jsonrpc":"2.0","method":"tools/call","params":{...},"id":"..." }
```

- [ ] **Step 4: Re-run MCP tests**
Run: `yarn nx test playground --testPathPattern=mcp-page.component.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/playground/src/app/modules/component-playground apps/playground/src/app/modules/mcp apps/playground/src/app/app.module.ts apps/playground/src/app/app.component.html apps/playground/src/app/main.component.html
git commit -m "feat(playground): add live component playground and MCP demo routes"
```

---

## Chunk 4: Real E2E Verification + Demo Operations

### Task 10: Add strict real-backend E2E coverage for all 4 streams

**Files:**
- Create: `apps/playground-e2e/src/e2e/live-demo-renderer.cy.ts`
- Create: `apps/playground-e2e/src/e2e/live-demo-chat.cy.ts`
- Create: `apps/playground-e2e/src/e2e/live-demo-component-playground.cy.ts`
- Create: `apps/playground-e2e/src/e2e/live-demo-mcp.cy.ts`
- Modify: `apps/playground-e2e/src/support/commands.ts`
- Modify: `apps/playground-e2e/src/support/e2e.ts`

- [ ] **Step 1: Add failing E2E for renderer without intercept stubs**
```ts
cy.visit('/generative');
cy.contains('Live service required').should('not.exist');
```

- [ ] **Step 2: Run single E2E spec and confirm fail**
Run: `yarn nx run playground-e2e:e2e --spec apps/playground-e2e/src/e2e/live-demo-renderer.cy.ts`
Expected: FAIL until live flow is wired.

- [ ] **Step 3: Repeat for chat/components/mcp specs**
Run: `yarn nx run playground-e2e:e2e --spec apps/playground-e2e/src/e2e/live-demo-chat.cy.ts`
Expected: PASS after implementation.

- [ ] **Step 4: Run full live-demo suite**
Run: `yarn nx run playground-e2e:e2e`
Expected: PASS across all live-demo specs.


### Task 11: Add preflight script and runbook commands

**Files:**
- Create: `scripts/live-demo-preflight.mjs`
- Modify: `package.json`
- Modify: `README.md`

- [ ] **Step 1: Add failing script test/manual run**
Run: `node scripts/live-demo-preflight.mjs`
Expected: FAIL when required env vars/endpoints are missing.

- [ ] **Step 2: Implement endpoint/env/auth checks**
```js
await assertReachable(process.env.AG_UI_URL);
await assertReachable(process.env.MCP_URL);
await assertReachable(process.env.OPENAI_URL);
```

- [ ] **Step 3: Add script entry + docs**
Run: `yarn live:preflight`
Expected: clear pass/fail output with actionable diagnostics.

- [ ] **Step 4: Final verification**
Run: `yarn nx test playground && yarn nx build playground && yarn nx run playground-e2e:e2e`
Expected: all pass with real backends online.

- [ ] **Step 5: Commit**
```bash
git add apps/playground-e2e scripts/live-demo-preflight.mjs package.json README.md
git commit -m "test(playground): add real-backend live demo verification and preflight gate"
```

---

## Execution Notes

- Use @superpowers:test-driven-development for each task loop (fail -> minimal pass -> refactor).
- Use @superpowers:verification-before-completion before reporting each chunk complete.
- Keep route-level blocking behavior explicit; do not silently degrade to fake data.
- Preserve existing unrelated changes in the workspace.

