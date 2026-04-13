<a href="https://api.reuse.software/info/github.com/SAP/ui5-webcomponents-ngx" target="_blank">
  <img src="https://api.reuse.software/badge/github.com/SAP/ui5-webcomponents-ngx" alt="REUSE status">
</a>

# UI5 Web Components for Angular

## About this project

This is a wrapper around [@ui5/webcomponents](https://sap.github.io/ui5-webcomponents) project to make it work with
Angular without
needing to use the [CUSTOM_ELEMENTS_SCHEMA](https://angular.io/api/core/CUSTOM_ELEMENTS_SCHEMA)
or [NO_ERRORS_SCHEMA](https://angular.io/api/core/NO_ERRORS_SCHEMA) schemas,
while providing full type safety and access to underlying web components in a type safe environment.
Everything that works and is available on the [@ui5/webcomponents](https://sap.github.io/ui5-webcomponents) side.

## Requirements and Setup

* Angular 16 or higher (tested with Angular 20). Other versions will not work because of the new Angular `required` inputs feature.

### Installation

Via npm:

```bash
npm install @ui5/webcomponents-ngx
```

Via yarn:

```bash
yarn add @ui5/webcomponents-ngx
```

### Usage

Import the module in your `app.module.ts` file:

```typescript
import { BrowserModule } from '@angular/platform-browser';
import { NgModule } from '@angular/core';
import { AppComponent } from './app.component';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx'; // here it is

@NgModule({
  declarations: [
    AppComponent
  ],
  imports: [
    BrowserModule,
    Ui5WebcomponentsModule
  ],
  providers: [],
  bootstrap: [AppComponent]
})
export class AppModule {
}
```

And that is it, you can now use any component described in
the [@ui5/webcomponents](https://sap.github.io/ui5-webcomponents)
documentation.

### Using Angular Components Inside UI5 Components

Angular components often use selectors with hyphens (e.g. `<app-item>`, `<app-value>`).
UI5 interprets such tags as custom elements and may wait **up to 1 second** for their registration, causing delayed rendering inside components like `<ui5-table-cell>`.

To avoid this, configure UI5 to ignore Angular component prefixes:

```ts
// ui5-init.ts
import { ignoreCustomElements } from '@ui5/webcomponents-base/dist/IgnoreCustomElements.js';

ignoreCustomElements('app-');
```

Import it before Angular bootstraps:
```ts
// main.ts
import './ui5-init';
```

This prevents unnecessary waiting, ensures smooth rendering, and improves performance when mixing Angular components with UI5 Web Components.

### Angular Forms

Every form-capable component can be used with Angular's native form approaches. Meaning all the
`formControlName` and `ngModel`s will work as expected.

## Versions

Angular Versions Support: Our versions offer Angular support. More information can be found [here](https://github.com/SAP/ui5-webcomponents-ngx/wiki/Angular-Versions-Support).

---

## Generative AI Workspace — Development Setup

This monorepo includes a full **Generative UI** stack on top of the Angular wrapper library. The following services are needed to use the Joule AI and Collaboration features.

### Prerequisites

| Tool | Version |
|------|---------|
| Node.js | 18 LTS or 20 LTS |
| Yarn | 4.x (`corepack enable`) |
| nx | installed via workspace devDependencies |

### 1. Install Dependencies

```bash
# Root monorepo (Angular + Nx)
yarn install

# MCP server (standalone Node package)
npm --prefix mcp-server install
```

### 2. Configure Environment Variables

```bash
cp .env.example .env
```

Edit `.env` and fill in the values for the services you want to use:

| Variable | Description | Required for |
|----------|-------------|--------------|
| `MANGLE_ENDPOINT` | Mangle reasoning engine URL | Joule AI |
| `HANA_BASE_URL` / `HANA_AUTH_URL` / `HANA_CLIENT_ID` / `HANA_CLIENT_SECRET` | SAP HANA Cloud REST SQL | Persistent audit/metrics |
| `AICORE_CLIENT_ID` / `AICORE_CLIENT_SECRET` / `AICORE_AUTH_URL` / `AICORE_BASE_URL` | SAP AI Core credentials | OpenAI-compat server |
| `MCP_AUTH_TOKEN` | Bearer token for `/mcp` endpoint | MCP server (optional for localhost) |
| `OPENAI_INTERNAL_TOKEN` | Internal token for `/v1/hana/*` routes | OpenAI-compat server |
| `OPENAI_OCR_INTERNAL_TOKEN` | Internal token for `/v1/ocr/*` routes (`X-OCR-Token`) | OCR extraction routes |
| `OPENAI_OCR_MAX_UPLOAD_BYTES` / `OPENAI_OCR_ALLOWED_MIME_TYPES` | OCR upload size and MIME guardrails | OCR extraction routes |

> **Note:** All services degrade gracefully when credentials are not set — the app starts and in-memory fallbacks are used.

### OCR token wiring (frontend)

The workspace sends OCR auth header from Angular environment config:

```ts
// apps/workspace/src/environments/environment.ts
export const environment = {
  // ...
  ocrInternalToken: '',
};
```

- If `ocrInternalToken` is empty, no `X-OCR-Token` header is sent.
- If set, OCR requests include `X-OCR-Token: <value>`.
- For secured deployments, set both:
  - backend `OPENAI_OCR_INTERNAL_TOKEN`
  - frontend `environment.ocrInternalToken` (or equivalent build-time replacement)

### 3. Start All Services

```bash
# Start everything (workspace + MCP server + OpenAI-compat server)
yarn start:all
```

Or start services individually:

```bash
yarn start:workspace   # Angular dev server on http://localhost:4200
yarn start:mcp          # MCP server on http://localhost:9160
yarn start:openai       # OpenAI-compat server on http://localhost:8400
```

The Angular dev server proxies `/ag-ui/*` to the MCP server automatically via `apps/workspace/proxy.conf.js`. Override the target with:

```bash
AGENT_URL=http://my-agent:9160 yarn start:workspace
```

### 4. Workspace Routes

| Route | Description |
|-------|-------------|
| `/` | Landing page — links to all work areas |
| `/forms` | UI5 form components with Angular reactive forms |
| `/joule` | Joule AI — generative UI driven by AG-UI streaming |
| `/collab` | Real-time multi-user collaboration workspace |
| `/generative` | Strict live schema generation and renderer flow |
| `/components` | Live component/model catalog from OpenAI-compatible backend |
| `/mcp` | Live MCP tools discovery and invocation |
| `/ocr` | Document intelligence — invoice and document extraction |
| `/readiness` | Service health dashboard and readiness checks |
| `/workspace` | Workspace settings — theme, language, nav preferences |
| `/**` | 404 Not Found page |

### 5. Building for Production

```bash
yarn build:prod
# Output: dist/apps/workspace/
```

### 6. Running Unit Tests

```bash
yarn nx test ui5-angular
```

### 7. Harness-Based Workspace Operation

Use the UI5 harness for deterministic preflight checks and machine-readable output:

```bash
# Flexible local mode (allows degraded behavior)
yarn harness:run --mode dev-flex --profile local-live

# Strict workspace mode (real backend requirements enforced)
yarn harness:workspace

# Strict CI mode with live e2e included
yarn harness:ci
```

Reports are written to `artifacts/harness/workspace-report.json` and `artifacts/harness/workspace-report.md`.

### 7. Live Workspace Readiness and E2E

For server-hosted deployments, operators can run readiness checks directly in the UI from the global **Service Health** panel (Shell header area) using the **Check Now** action.

Run readiness checks before a live workspace session:

```bash
yarn live:preflight
```

Optional env vars for non-default hosts:

```bash
AG_UI_URL=http://localhost:9160/health \
OPENAI_URL=http://localhost:8400/health \
MCP_URL=http://localhost:9160/health \
MCP_RPC_URL=http://localhost:9160/mcp \
yarn live:preflight
```

Run live-only E2E (no AG-UI stubs/intercepts):

```bash
yarn e2e:live
```

Run repeatable workspace readiness checks (preflight + live pages + learn path):

```bash
yarn readiness:verify
```

Customize repetitions:

```bash
READINESS_VERIFY_ATTEMPTS=3 yarn readiness:verify
```

### 8. Architecture Overview

```
apps/
  workspace/          Angular app — Fiori shell, lazy-loaded feature modules

libs/
  ui5-angular/         Angular wrapper for @ui5/webcomponents (main library)
  ag-ui-angular/       AG-UI client (SSE/WebSocket), tool registry, JouleChatComponent
  genui-renderer/      Dynamic UI renderer from A2UiSchema
  genui-streaming/     SSE streaming session management (StreamingUiService)
  genui-governance/    Action review panel, audit log, policy enforcement
  genui-collab/        Real-time CRDT-backed collaboration (WebSocket)
  openai-server/       OpenAI-compatible proxy → SAP AI Core + HANA Vector

mcp-server/            MCP server — Express + Mangle reasoning
```

---

## Support, Feedback, Contributing

For an overview on how this library works, see the [SAP Contribution Guidelines](https://github.com/SAP/.github/blob/main/CONTRIBUTING.md), the [Maintainers](https://github.com/SAP/ui5-webcomponents-ngx/blob/main/MAINTAINERS.md) documentation.

This project is open to feature requests/suggestions, bug reports etc.
via [GitHub issues](https://github.com/SAP/ui5-webcomponents-ngx/issues). Contribution and feedback are encouraged and
always welcome. For more information about how to contribute, the project structure, as well as additional contribution
information, see our [Contribution Guidelines](https://github.com/SAP/ui5-webcomponents-ngx/blob/main/CONTRIBUTING.md).

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for
everyone. By participating in this project, you agree to abide by
its [Code of Conduct](https://github.com/SAP/ui5-webcomponents-ngx/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2022 SAP SE or an SAP affiliate company and ui5-webcomponents-ngx contributors. Please see
our [LICENSE](https://github.com/SAP/ui5-webcomponents-ngx/blob/main/LICENSES/Apache-2.0.txt) for copyright and license
information. Detailed information including third-party components and their licensing/copyright information is
available [via the REUSE tool](https://api.reuse.software/info/github.com/SAP/ui5-webcomponents-ngx).
