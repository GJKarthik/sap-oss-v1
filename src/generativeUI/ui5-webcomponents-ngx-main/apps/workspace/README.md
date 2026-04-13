# Workspace App

Angular 20 developer workspace and sample shell for the UI5 Web Components for Angular library.

## Overview

This app demonstrates the full UI5 Angular wrapper library in a production-style shell with:
- **Side navigation** (ui5-side-navigation) with dynamic nav links from workspace settings
- **Spotlight search** (Cmd/K) with pinning, recent pages, and ranked search
- **Learn-path onboarding** across generative, Joule, components, and MCP routes
- **i18n** for 7 languages (en, de, fr, zh, ko, ar, id)
- **Theming** with Horizon and Horizon Dark
- **Lazy-loaded feature modules** for forms, Joule, collaboration, generative UI, model catalog, MCP tools, OCR, readiness, and workspace settings

## Development

```bash
# From the monorepo root
yarn start:workspace   # http://localhost:4200
```

The dev server proxies `/ag-ui/*` and other backend routes via `proxy.conf.js`.

## Architecture

- **Bootstrap**: Standalone `bootstrapApplication` via `app.config.ts`
- **Shell**: `AppComponent` (standalone) hosts shellbar, sidebar, router-outlet, and spotlight
- **Home**: `MainComponent` (standalone) with configurable widget grid
- **Features**: Lazy-loaded NgModules under `modules/`
- **Core services**: WorkspaceService, QuickAccessService, LearnPathService, ExperienceHealthService

## Testing

### Unit tests (default PR CI)

Runs in [.github/workflows/ci-workspace.yml](../../../../../.github/workflows/ci-workspace.yml): lint, **Jest unit tests**, and production build. Those tests use mocks and doubles; they validate component/service logic in isolation, not full SAP/BTP integration.

```bash
yarn nx test workspace
```

**HTTP integration samples:** [`src/app/core/experience-health.capabilities.http.spec.ts`](src/app/core/experience-health.capabilities.http.spec.ts) uses `HttpTestingController` (real Angular `HttpClient` pipeline) for `GET …/capabilities` URL and response mapping—still no live server.

### E2E (Cypress) and live backends

```bash
yarn nx run workspace-e2e:e2e
```

Specs under `apps/workspace-e2e` that use `describeLive` run only when `CYPRESS_LIVE_BACKENDS=true` (or `LIVE_BACKENDS` in Cypress env). Start backends first, for example:

```bash
# From repo root — publishes training-api:8000 and ui5-mcp:9160 on the host
docker compose -f src/generativeUI/docker-compose.yml -f src/generativeUI/docker-compose.workspace-e2e.yml up -d --build training-api ui5-mcp

export TRAINING_API_URL=http://localhost:8000 AGENT_URL=http://localhost:9160
export CYPRESS_LIVE_BACKENDS=true
cd src/generativeUI/ui5-webcomponents-ngx-main && yarn nx run workspace-e2e:e2e --configuration=ci
```

### Stack-level CI (manual / weekly)

[.github/workflows/ci-workspace-integration.yml](../../../../../.github/workflows/ci-workspace-integration.yml) — `workflow_dispatch` and weekly schedule: Docker compose (same overlay), waits for `/health`, curls `/capabilities`, then Cypress with live flags.

### Gateway smoke (suite reverse proxy)

With the suite gateway listening (e.g. port 8080):

```bash
GATEWAY_URL=http://localhost:8080 bash src/generativeUI/gateway/scripts/smoke-public-paths.sh
```
