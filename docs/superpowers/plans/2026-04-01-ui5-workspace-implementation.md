# UI5 Workspace Experience Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a real, end-to-end workspace experience in `ui5-webcomponents-ngx-main` with four production-like flows (Generative Renderer, Joule Chat, Model Catalog, MCP Integration) using real backends only.

**Architecture:** Extend `apps/workspace` into a single workspace shell with dedicated feature routes and shared runtime health/diagnostics. Implement feature streams sequentially (deep build): renderer -> chat -> model catalog -> MCP flow. Add route-level readiness guards, typed API clients, and real E2E verification for each stream.

**Tech Stack:** Angular 20, Nx, UI5 Web Components, existing `@ui5/genui-*` libs, MCP server (`mcp-server`), OpenAI server (`libs/openai-server`), Cypress E2E, Jest unit tests.

---

## File Structure (Planned Changes)

**Create**
- `apps/workspace/src/app/core/workspace-config.ts`
- `apps/workspace/src/app/core/experience-health.service.ts`
- `apps/workspace/src/app/core/request-trace.interceptor.ts`
- `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.ts`
- `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.html`
- `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.scss`
- `apps/workspace/src/app/modules/model-catalog/model-catalog.module.ts`
- `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.ts`
- `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.html`
- `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.scss`
- `apps/workspace/src/app/modules/mcp/mcp.module.ts`
- `apps/workspace/src/app/modules/mcp/mcp-page.component.ts`
- `apps/workspace/src/app/modules/mcp/mcp-page.component.html`
- `apps/workspace/src/app/modules/mcp/mcp-page.component.scss`
- `apps/workspace/src/app/modules/generative/generative-runtime.service.ts`
- `apps/workspace/src/app/modules/generative/generative-contracts.ts`
- `apps/workspace-e2e/src/e2e/live-renderer.cy.ts`
- `apps/workspace-e2e/src/e2e/live-chat.cy.ts`
- `apps/workspace-e2e/src/e2e/live-model-catalog.cy.ts`
- `apps/workspace-e2e/src/e2e/live-mcp.cy.ts`
- `scripts/readiness-check.mjs`

**Modify**
- `apps/workspace/src/environments/environment.ts`
- `apps/workspace/src/environments/environment.prod.ts`
- `apps/workspace/src/app/app.module.ts`
- `apps/workspace/src/app/app.component.html`
- `apps/workspace/src/app/app.component.ts`
- `apps/workspace/src/app/main.component.html`
- `apps/workspace/src/app/main.component.ts`
- `apps/workspace/src/app/modules/generative/generative-page.component.ts`
- `apps/workspace/src/app/modules/generative/generative.module.ts`
- `apps/workspace/src/app/modules/joule/joule-shell.component.ts`
- `apps/workspace/src/app/modules/joule/joule-shell.component.html`
- `apps/workspace-e2e/src/support/commands.ts`
- `apps/workspace-e2e/src/support/e2e.ts`
- `apps/workspace-e2e/cypress.config.ts`
- `package.json`
- `README.md`

**Test**
- `apps/workspace/src/app/modules/generative/generative-page.component.spec.ts`
- `apps/workspace/src/app/modules/joule/joule-shell.component.spec.ts`
- `apps/workspace/src/app/core/experience-health.service.spec.ts`
- `apps/workspace/src/app/modules/mcp/mcp-page.component.spec.ts`

---

## Chunk 1: Core Workspace Infrastructure

### Task 1: Add strict workspace runtime config

**Files:**
- Create: `apps/workspace/src/app/core/workspace-config.ts`
- Modify: `apps/workspace/src/environments/environment.ts`
- Modify: `apps/workspace/src/environments/environment.prod.ts`
- Test: `apps/workspace/src/app/core/experience-health.service.spec.ts`

- [ ] **Step 1: Write failing config test**
```ts
it('requires real service URLs in live mode', () => {
  expect(() => validateWorkspaceConfig({ mcpBaseUrl: '' } as any)).toThrow();
});
```

- [ ] **Step 2: Run test to verify it fails**
Run: `yarn nx test workspace --testPathPattern=experience-health.service.spec.ts`
Expected: FAIL with missing config validator.

- [ ] **Step 3: Implement live config + validator**
```ts
export interface WorkspaceConfig {
  agUiEndpoint: string;
  openAiBaseUrl: string;
  mcpBaseUrl: string;
  requireRealBackends: true;
}
```

- [ ] **Step 4: Run targeted test**
Run: `yarn nx test workspace --testPathPattern=experience-health.service.spec.ts`
Expected: PASS for config validation.


### Task 2: Add shared health service + diagnostics model

**Files:**
- Create: `apps/workspace/src/app/core/experience-health.service.ts`
- Test: `apps/workspace/src/app/core/experience-health.service.spec.ts`

- [ ] **Step 1: Write failing service tests**
```ts
it('marks route blocked when required service is down', async () => {
  // arrange failing probe
  expect(result.blocking).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it fails**
Run: `yarn nx test workspace --testPathPattern=experience-health.service.spec.ts`
Expected: FAIL on missing service implementation.

- [ ] **Step 3: Implement probe + route gating**
```ts
checkRouteReadiness(route: 'generative'|'joule'|'components'|'mcp'): Observable<RouteReadiness>;
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test workspace --testPathPattern=experience-health.service.spec.ts`
Expected: PASS.


### Task 3: Add request tracing interceptor (correlation IDs)

**Files:**
- Create: `apps/workspace/src/app/core/request-trace.interceptor.ts`
- Modify: `apps/workspace/src/app/app.module.ts`

- [ ] **Step 1: Write failing interceptor test**
```ts
expect(req.headers.has('x-correlation-id')).toBe(true);
```

- [ ] **Step 2: Run test and confirm fail**
Run: `yarn nx test workspace --testPathPattern=request-trace`
Expected: FAIL no interceptor wired.

- [ ] **Step 3: Implement interceptor + provider registration**
```ts
const requestId = crypto.randomUUID();
req = req.clone({ setHeaders: { 'x-correlation-id': requestId } });
```

- [ ] **Step 4: Re-run tests**
Run: `yarn nx test workspace --testPathPattern=request-trace`
Expected: PASS.


### Task 4: Add reusable health panel component

**Files:**
- Create: `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.ts`
- Create: `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.html`
- Create: `apps/workspace/src/app/shared/service-health-panel/service-health-panel.component.scss`
- Modify: `apps/workspace/src/app/app.component.html`

- [ ] **Step 1: Write failing render test**
```ts
expect(screen.getByText(/Service Health/i)).toBeTruthy();
```

- [ ] **Step 2: Run test to verify fail**
Run: `yarn nx test workspace --testPathPattern=service-health-panel`
Expected: FAIL component not found.

- [ ] **Step 3: Implement health panel**
```html
<ui5-message-strip [design]="blocking ? 'Negative' : 'Positive'">
  {{ summaryText }}
</ui5-message-strip>
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test workspace --testPathPattern=service-health-panel`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/workspace/src/app/core apps/workspace/src/app/shared apps/workspace/src/environments docs/superpowers/specs/2026-04-01-ui5-workspace-design.md
git commit -m "feat(workspace): add live backend health and request tracing foundation"
```

---

## Chunk 2: Deep Build 1 + 2 (Generative Renderer, Joule Chat)

### Task 5: Replace simulated generative flow with real runtime service

**Files:**
- Create: `apps/workspace/src/app/modules/generative/generative-runtime.service.ts`
- Create: `apps/workspace/src/app/modules/generative/generative-contracts.ts`
- Modify: `apps/workspace/src/app/modules/generative/generative-page.component.ts`
- Test: `apps/workspace/src/app/modules/generative/generative-page.component.spec.ts`

- [ ] **Step 1: Add failing spec for real API call behavior**
```ts
it('does not render fake schema when backend call fails', () => {
  expect(component.loading).toBe(false);
  expect(component.uiSchema).toBeNull();
});
```

- [ ] **Step 2: Run spec to fail**
Run: `yarn nx test workspace --testPathPattern=generative-page.component.spec.ts`
Expected: FAIL (current setTimeout simulation path still present).

- [ ] **Step 3: Implement runtime service + remove setTimeout simulation**
```ts
this.runtime.generateSchema(prompt).subscribe({
  next: (schema) => this.uiSchema = schema,
  error: (err) => this.lastError = mapBackendError(err)
});
```

- [ ] **Step 4: Re-run generative tests**
Run: `yarn nx test workspace --testPathPattern=generative-page.component.spec.ts`
Expected: PASS.


### Task 6: Add readiness gate + diagnostics to generative route

**Files:**
- Modify: `apps/workspace/src/app/modules/generative/generative-page.component.ts`
- Modify: `apps/workspace/src/app/modules/generative/generative.module.ts`

- [ ] **Step 1: Add failing spec for blocked route when service down**
```ts
expect(component.blockingReason).toContain('AG-UI');
```

- [ ] **Step 2: Run spec to confirm fail**
Run: `yarn nx test workspace --testPathPattern=generative-page.component.spec.ts`
Expected: FAIL.

- [ ] **Step 3: Implement live readiness gate**
```ts
if (readiness.blocking) { this.blockingReason = readiness.message; return; }
```

- [ ] **Step 4: Run tests**
Run: `yarn nx test workspace --testPathPattern=generative-page.component.spec.ts`
Expected: PASS.


### Task 7: Harden Joule route for real streaming + explicit backend diagnostics

**Files:**
- Modify: `apps/workspace/src/app/modules/joule/joule-shell.component.ts`
- Modify: `apps/workspace/src/app/modules/joule/joule-shell.component.html`
- Test: `apps/workspace/src/app/modules/joule/joule-shell.component.spec.ts`

- [ ] **Step 1: Add failing spec for backend-specific error output**
```ts
expect(fixture.nativeElement.textContent).toContain('AG-UI endpoint');
expect(fixture.nativeElement.textContent).toContain('x-correlation-id');
```

- [ ] **Step 2: Run Joule tests and confirm fail**
Run: `yarn nx test workspace --testPathPattern=joule-shell.component.spec.ts`
Expected: FAIL.

- [ ] **Step 3: Implement typed error mapping and readiness checks**
```ts
this.connectionError = `AG-UI endpoint unavailable (${status}) [${correlationId}]`;
```

- [ ] **Step 4: Re-run Joule tests**
Run: `yarn nx test workspace --testPathPattern=joule-shell.component.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/workspace/src/app/modules/generative apps/workspace/src/app/modules/joule apps/workspace/src/app/core
git commit -m "feat(workspace): switch generative and joule flows to strict live backend execution"
```

---

## Chunk 3: Deep Build 3 + 4 (Model Catalog, MCP Flow)

### Task 8: Build live model catalog route (real metadata source)

**Files:**
- Create: `apps/workspace/src/app/modules/model-catalog/model-catalog.module.ts`
- Create: `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.ts`
- Create: `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.html`
- Create: `apps/workspace/src/app/modules/model-catalog/model-catalog-page.component.scss`
- Modify: `apps/workspace/src/app/app.module.ts`
- Modify: `apps/workspace/src/app/app.component.html`
- Modify: `apps/workspace/src/app/main.component.html`

- [ ] **Step 1: Add failing component route test**
```ts
expect(router.url).toBe('/components');
```

- [ ] **Step 2: Run tests to verify fail**
Run: `yarn nx test workspace --testPathPattern=model-catalog`
Expected: FAIL route/module missing.

- [ ] **Step 3: Implement route + live metadata fetch**
```ts
this.http.get<ComponentCatalog>(`${env.openAiBaseUrl}/v1/ui/components`).subscribe(...)
```

- [ ] **Step 4: Re-run tests**
Run: `yarn nx test workspace --testPathPattern=model-catalog`
Expected: PASS.


### Task 9: Build MCP route with real tool discovery + invoke

**Files:**
- Create: `apps/workspace/src/app/modules/mcp/mcp.module.ts`
- Create: `apps/workspace/src/app/modules/mcp/mcp-page.component.ts`
- Create: `apps/workspace/src/app/modules/mcp/mcp-page.component.html`
- Create: `apps/workspace/src/app/modules/mcp/mcp-page.component.scss`
- Modify: `apps/workspace/src/app/app.module.ts`
- Modify: `apps/workspace/src/app/app.component.html`
- Test: `apps/workspace/src/app/modules/mcp/mcp-page.component.spec.ts`

- [ ] **Step 1: Add failing tests for list-tools and call-tool flows**
```ts
expect(component.tools.length).toBeGreaterThan(0);
expect(component.lastCallResult).toBeDefined();
```

- [ ] **Step 2: Run tests to fail**
Run: `yarn nx test workspace --testPathPattern=mcp-page.component.spec.ts`
Expected: FAIL no MCP module/component.

- [ ] **Step 3: Implement JSON-RPC MCP client and invoke UI**
```ts
POST /mcp { "jsonrpc":"2.0","method":"tools/list","id":"..." }
POST /mcp { "jsonrpc":"2.0","method":"tools/call","params":{...},"id":"..." }
```

- [ ] **Step 4: Re-run MCP tests**
Run: `yarn nx test workspace --testPathPattern=mcp-page.component.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/workspace/src/app/modules/model-catalog apps/workspace/src/app/modules/mcp apps/workspace/src/app/app.module.ts apps/workspace/src/app/app.component.html apps/workspace/src/app/main.component.html
git commit -m "feat(workspace): add live model catalog and MCP workspace routes"
```

---

## Chunk 4: Real E2E Verification + Demo Operations

### Task 10: Add strict real-backend E2E coverage for all 4 streams

**Files:**
- Create: `apps/workspace-e2e/src/e2e/live-renderer.cy.ts`
- Create: `apps/workspace-e2e/src/e2e/live-chat.cy.ts`
- Create: `apps/workspace-e2e/src/e2e/live-model-catalog.cy.ts`
- Create: `apps/workspace-e2e/src/e2e/live-mcp.cy.ts`
- Modify: `apps/workspace-e2e/src/support/commands.ts`
- Modify: `apps/workspace-e2e/src/support/e2e.ts`

- [ ] **Step 1: Add failing E2E for renderer without intercept stubs**
```ts
cy.visit('/generative');
cy.contains('Live service required').should('not.exist');
```

- [ ] **Step 2: Run single E2E spec and confirm fail**
Run: `yarn nx run workspace-e2e:e2e --spec apps/workspace-e2e/src/e2e/live-renderer.cy.ts`
Expected: FAIL until live flow is wired.

- [ ] **Step 3: Repeat for chat/components/mcp specs**
Run: `yarn nx run workspace-e2e:e2e --spec apps/workspace-e2e/src/e2e/live-chat.cy.ts`
Expected: PASS after implementation.

- [ ] **Step 4: Run full workspace suite**
Run: `yarn nx run workspace-e2e:e2e`
Expected: PASS across all workspace specs.


### Task 11: Add preflight script and runbook commands

**Files:**
- Create: `scripts/readiness-check.mjs`
- Modify: `package.json`
- Modify: `README.md`

- [ ] **Step 1: Add failing script test/manual run**
Run: `node scripts/readiness-check.mjs`
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
Run: `yarn nx test workspace && yarn nx build workspace && yarn nx run workspace-e2e:e2e`
Expected: all pass with real backends online.

- [ ] **Step 5: Commit**
```bash
git add apps/workspace-e2e scripts/readiness-check.mjs package.json README.md
git commit -m "test(workspace): add real-backend workspace experience verification and preflight gate"
```

---

## Execution Notes

- Use @superpowers:test-driven-development for each task loop (fail -> minimal pass -> refactor).
- Use @superpowers:verification-before-completion before reporting each chunk complete.
- Keep route-level blocking behavior explicit; do not silently degrade to fake data.
- Preserve existing unrelated changes in the workspace.
