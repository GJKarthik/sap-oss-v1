# Technical Assessment: `@sap-oss/sac-webcomponents-ngx`

**Package:** `@sap-oss/sac-webcomponents-ngx` v1.0.0  
**Author:** Nucleus Platform Team  
**License:** MIT  
**Repository:** `aiNucleusSdk/ainuc-sap-sdk/sac-webcomponents-ngx`  
**Runtime requirement:** Node.js ≥ 18, Angular ≥ 17

---

## Purpose and Positioning

This library is the Angular-layer integration kit for SAP Analytics Cloud (SAC). It occupies a position in the SAP open-source estate between the low-level SAC REST API and the application code written by Nucleus platform consumers. The package serves two distinct but related purposes simultaneously: it ships a collection of Angular component libraries that wrap SAC widget concepts into idiomatic Angular primitives, and it ships a fully self-contained SAC custom widget bundle that embeds an AI chat assistant into a SAC Designer story. These two outputs share a common authentication and transport foundation but are built and distributed differently.

The library is authored by the Nucleus Platform Team and carries an Apache-2.0 SPDX header on its widget entry point, with an MIT root license. The public npm namespace is `@sap-oss/sac-webcomponents-ngx`, with ten secondary entry points published as subpath exports. There is a hard break from previous internal namespace conventions: neither `@nucleus/*` nor `@sap-oss/sac-ngx*` import paths are supported, making this a clean v1 public contract with no legacy surface area.

---

## Repository Layout and Build Architecture

The workspace root is a single Angular CLI workspace (`angular.json`) whose `newProjectRoot` is `libs/`. Every Angular secondary entry point — `sac-core`, `sac-chart`, `sac-table`, `sac-input`, `sac-planning`, `sac-datasource`, `sac-widgets`, `sac-advanced`, `sac-builtins`, and `sac-calendar` — is a separate `ng-packagr` library project within that workspace. Each is built in dependency order by the root `build` script, which sequentially invokes `ng build <lib>` for each project after first building the standalone TypeScript SDK (`build:sdk`).

The TypeScript SDK (`libs/sac-sdk/`) is not an Angular library; it is a framework-agnostic TypeScript module compiled by `tsup` into an ESM `.mjs` bundle with a `.d.mts` declaration file. The SDK is the only entry point that carries no Angular dependency whatsoever, making it independently usable in Node.js scripts, non-Angular frontends, and test harnesses.

The SAC custom widget (`libs/sac-ai-widget/`) is also compiled by `tsup`, but into an IIFE bundle (`format: ['iife']`) targeting ES2022. The IIFE format is a requirement of the SAC Designer custom widget upload mechanism, which expects a single self-contained JavaScript file registered as a global. The build is intentionally non-minified by default (`build:widget-dev`) and minified for release (`build:widget`). The final upload artifact is `dist/releases/widget.zip`, assembled by `scripts/package-widget.js` by bundling the IIFE file alongside the `widget.json` descriptor.

The `prepack` lifecycle hook ensures that `npm run build` and `npm run build:widget` are run before `npm pack`, giving the package a hermetic packaging guarantee. The published tarball contains only `dist/**`, `README.md`, `RELEASE.md`, and `widget.json`; source trees, Angular caches, and build residue are excluded.

---

## Entry Point Map

| Entry point | Distribution format | Technology |
|---|---|---|
| `/sdk` | ESM `.mjs` + `.d.mts` | Plain TypeScript — no Angular |
| `/core` | FESM2022 `.mjs` | Angular NgModule library |
| `/chart` | FESM2022 `.mjs` | Angular NgModule library |
| `/table` | FESM2022 `.mjs` | Angular NgModule library |
| `/input` | FESM2022 `.mjs` | Angular NgModule library |
| `/planning` | FESM2022 `.mjs` | Angular NgModule library |
| `/datasource` | FESM2022 `.mjs` | Angular NgModule library |
| `/widgets` | FESM2022 `.mjs` | Angular NgModule library |
| `/advanced` | FESM2022 `.mjs` | Angular NgModule library |
| `/builtins` | FESM2022 `.mjs` | Angular NgModule library |
| `/calendar` | FESM2022 `.mjs` | Angular NgModule library |

All Angular entry points have TypeScript declarations at `dist/<lib>/index.d.ts`. The `/sdk` entry point uses the `.d.mts` convention to signal that its types are ESM-only. The `package.json` `exports` map uses a flat `"default"` key for Angular entries rather than `"import"`/`"require"` splits, reflecting the FESM2022 output being ESM-only and not dual-CJS.

---

## Core Architecture

### Transport and Authentication (`/sdk`, `/core`)

The foundational layer is `SACRestAPIClient` in `libs/sac-sdk/client.ts`. This class extends a lightweight `EventEmitter` built in-process (not RxJS) and wraps the native `fetch` API with configurable retry logic, request timeout via `AbortController`, response content-type negotiation, binary blob handling, and structured error normalisation into a typed `SACError` class. Retries are applied on network errors, timeouts, `408`, `429`, and any `5xx` response, with a configurable delay that back-offs linearly by attempt count. The client emits a structured `TelemetryData` event on every request completion, whether success or failure, to support observability wiring by the host application.

Authentication is designed for two modes: a static token supplied at construction time via `setAuthToken()`, or a dynamic token resolved at request time via the `getAuthToken` callback. The latter is the appropriate pattern for SAC widget scenarios where the session token is refreshed by the runtime. The client sets `X-SAC-API-Version` on every request, defaulting to `2025.19`.

The Angular layer wraps this client inside `SacCoreModule`, a standard `NgModule` with a `forRoot(config: SacConfig)` factory. The `forRoot` pattern provides three Angular injection tokens — `SAC_CONFIG`, `SAC_API_URL`, and `SAC_AUTH_TOKEN` — alongside four singleton services: `SacConfigService`, `SacApiService`, `SacAuthService`, and `SacEventService`. The `SacCoreModule` imports `HttpClientModule`, indicating the Angular entry points use `HttpClient` for their transport layer rather than the SDK's `fetch`-based client directly. This means the Angular libraries and the standalone SDK are operationally independent transport stacks that share only types and enums. Both authenticate using bearer tokens, and `SacAuthService` exposes `getToken()` and `setToken()` for programmatic token propagation.

### Type System and Enum Taxonomy

`libs/sac-sdk/types.ts` defines the complete shared type and enum vocabulary. The enum set is derived from SAC's ODPS (Open Data Protocol Specification) YAML spec files, with inline comments referencing source spec file names (e.g. `applicationmode_client.odps.yaml`, `chart_client.odps.yaml`, `layoutunit_client.odps.yaml`). This derivation gives consumers a typed view of the SAC domain model without a direct dependency on SAC's proprietary toolchain. The covered enumerations span application modes and device types, widget taxonomy (17 widget types), chart types (16 variants), datasource filter and variable types, planning categories and copy options, data locking states, calendar task types and statuses, and layout units. Interface definitions cover the full SAC application metadata model including permissions, versioning, dependencies, usage telemetry, and shared user representations.

The same enums are re-exported from the Angular `/core` entry point, meaning consumers of either the Angular libraries or the standalone SDK operate against an identical type surface.

### Mangle Datalog Specifications

The `mangle/` directory contains three `.mg` files written in a Datalog dialect referred to as Mangle. These specifications — `sac_widget.mg`, `sac_datasource.mg`, and `sac_planning.mg` — define fact bases and derivation rules that mechanically produce Angular component structure from the SAC widget type taxonomy. Rules in `sac_widget.mg` derive Angular component selector names (e.g. `sac-chart`), module class names (e.g. `SacChartModule`), service class names, and standard input/output property sets from the base `widget_category` facts. The datasource and planning spec files follow the same pattern for their respective domain models.

The `generate` script (`node scripts/generate-from-mangle.js`) and `mangle:validate` script indicate that parts of the Angular library source are generated from, or validated against, these Mangle specs. This is a code generation contract: the specs are the authoritative source of truth for component shape, and the Angular TypeScript code is a derived artefact. This pattern reduces the risk of drift between the SAC domain model and the Angular component API surface.

---

## The SAC AI Widget

### Concept and Integration Model

The SAC AI Widget (`libs/sac-ai-widget/`) is the most architecturally complex component in the repository. It is a SAC Custom Widget — a standard SAC extensibility mechanism — that embeds a complete Angular 17 application inside a Web Component registered as the custom element `sac-ai-widget`. The widget presents a two-panel layout: a chat panel on the left (320px fixed width) and a data visualisation panel on the right. A single AI conversation session is shared between both panels, so an LLM response can simultaneously stream text into the chat panel and mutate the chart or table state in the data panel.

The widget is configured entirely through SAC Designer properties defined in `widget.json`. The five designer-editable properties are `capBackendUrl` (the URL of the CAP LLM Plugin backend on BTP Cloud Foundry), `tenantUrl` (the SAC tenant URL), `modelId` (the default datasource model identifier), `widgetType` (initial visualisation mode: `chart`, `table`, or `kpi`), and `sacBearerToken` (the SAC session token, which SAC injects at runtime). This configuration surface makes the widget deployable without any code changes: operators configure it entirely through the SAC Designer property panel.

### Angular Bootstrap Inside the SAC Lifecycle

The entry class `SacAiWidgetEntry` in `sac-ai-widget.entry.ts` extends `HTMLElement` directly, implementing the three SAC Custom Widget lifecycle callbacks: `onCustomWidgetBeforeUpdate`, `onCustomWidgetAfterUpdate`, and `onCustomWidgetDestroy`. On `onCustomWidgetAfterUpdate`, the widget bootstraps an Angular application using `createApplication` from `@angular/platform-browser`, wires providers for `SacCoreModule.forRoot(...)` plus the three widget-scoped injection tokens (`SAC_AI_BACKEND_URL`, `SAC_TENANT_URL`, `SAC_MODEL_ID`), and then uses `createComponent` to mount `SacAiChatPanelComponent` and `SacAiDataWidgetComponent` into a Shadow DOM subtree. The Shadow DOM provides CSS isolation from SAC's host stylesheet.

The bootstrap is re-triggered if `capBackendUrl` or `tenantUrl` change in designer properties, since these are constructor-time dependencies for the Angular DI tree. Token changes — the more frequent case during live editing — are applied without re-bootstrap by calling `SacAuthService.setToken()` directly on the already-running application injector. This distinction between cold re-bootstrap paths and hot token-update paths is an explicit design decision visible in the `onCustomWidgetAfterUpdate` implementation.

### AG-UI Protocol and LLM Streaming

The AI backend integration uses the AG-UI (Agent UI) protocol over Server-Sent Events. `SacAgUiService` in `libs/sac-ai-widget/ag-ui/sac-ag-ui.service.ts` posts a `SacAgUiRunRequest` to `/ag-ui/run` on the CAP LLM Plugin backend, then reads the streaming SSE response body using the `ReadableStream` API and emits strongly-typed `AgUiEvent` objects as an RxJS `Observable`. The service manages active stream cancellation through `AbortController` references held in a `Set`, so unsubscribing from the observable aborts the underlying HTTP connection. The AG-UI event type vocabulary includes `RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`, `STEP_STARTED`, `STEP_FINISHED`, `TEXT_MESSAGE_START`, `TEXT_MESSAGE_CONTENT`, `TEXT_MESSAGE_END`, `TOOL_CALL_START`, `TOOL_CALL_ARGS`, `TOOL_CALL_END`, `TOOL_CALL_RESULT`, `STATE_SNAPSHOT`, `STATE_DELTA`, `MESSAGES_SNAPSHOT`, and `CUSTOM`.

`SacAiChatPanelComponent` subscribes to the observable and applies a streaming-delta accumulation pattern: `TEXT_MESSAGE_CONTENT` events carry a `delta` string that is appended to the active assistant message content, and Angular's `OnPush` change detection strategy with explicit `markForCheck()` calls ensures the chat UI updates token-by-token without triggering full tree diffing. The component uses inline template and styles (no external files), which is intentional for the IIFE widget build where all content must be self-contained.

### Frontend Tool Dispatch Loop

When the LLM decides to call a tool, it streams `TOOL_CALL_START` followed by incremental `TOOL_CALL_ARGS` JSON fragments, then `TOOL_CALL_END`. `SacAiChatPanelComponent` accumulates the argument fragments in a `Map<toolCallId, string>` and on `TOOL_CALL_END` calls `SacToolDispatchService.execute(toolName, args)`. `SacToolDispatchService` implements five tool handlers: `set_datasource_filter`, `set_chart_type`, `run_data_action`, `get_model_dimensions`, and `generate_sac_widget`. These tools mutate the data widget's state by calling `applySchema()` on a registered `WidgetStateTarget` interface, which `SacAiDataWidgetComponent` satisfies. Tool results are posted back to the backend via `SacAgUiService.dispatchToolResult()` at `/ag-ui/tool-result`. This bidirectional loop — LLM calls tool, frontend executes it against the live SAC widget, result returned to backend — constitutes the agentic reasoning layer that enables natural-language analytics queries to produce live chart and table mutations.

---

## Software Bill of Materials

### Runtime Peer Dependencies

These are not bundled; they must be provided by the host application.

| Package | Required version | Purpose |
|---|---|---|
| `@angular/common` | ≥ 17.0.0 | Angular common primitives |
| `@angular/core` | ≥ 17.0.0 | Angular core DI and component model |
| `@angular/forms` | ≥ 17.0.0 | Angular forms integration |
| `rxjs` | ≥ 7.0.0 | Reactive streams |
| `tslib` | ≥ 2.3.0 | TypeScript runtime helpers |
| `zone.js` | ≥ 0.14.0 | Angular change detection |

The SDK entry point (`/sdk`) has zero peer dependencies. The IIFE widget bundle inlines all dependencies at build time, including `zone.js` and `@angular/compiler` (imported explicitly at the top of `sac-ai-widget.entry.ts`), so the widget `.zip` has no external runtime requirements beyond a modern browser.

### Development Dependencies (build-time only, not shipped)

| Package | Pinned version | Role |
|---|---|---|
| `@angular/cli` | ^17.3.0 | Angular CLI — `ng build` driver |
| `@angular-devkit/build-angular` | ^17.3.0 | ng-packagr orchestration |
| `ng-packagr` | ^17.3.0 | Angular library compilation and FESM bundling |
| `tsup` | ^8.0.0 | SDK and widget IIFE bundler |
| `typescript` | ~5.4.0 | TypeScript compiler |
| `vitest` | ^4.0.18 | Unit test runner |
| `playwright` | ^1.58.2 | Browser-level smoke harness for built widget |
| `eslint` | ^10.0.3 | Linting gate |
| `typescript-eslint` | ^8.56.1 | TypeScript ESLint rules |
| `@types/node` | ^20.0.0 | Node.js type definitions |
| `globals` | ^17.4.0 | ESLint globals configuration |

The TypeScript compiler is pinned to the patch range `~5.4.0` rather than a caret range. This is a deliberate choice to avoid silent breakage from TypeScript minor releases, which can introduce type-checking regressions in large codebases.

### Transitive Dependency Notes

The `package-lock.json` at 543 KB indicates a moderate-sized transitive closure. The Angular CLI and devkit bring the heaviest transitive tree. None of the transitive dependencies are shipped in the published npm tarball because the `files` field in `package.json` is scoped to `dist/**`, `README.md`, `RELEASE.md`, and `widget.json`; `node_modules/` is excluded entirely.

---

## Testing Strategy

The `tests/` directory contains eight test files run by Vitest in a `node` environment with Angular bootstrapped through a `setup-angular.ts` test setup file. The test suite covers `SACRestAPIClient` HTTP behaviour (including retry logic, timeout, and auth header resolution), `SacAuthService`, `SacChartService`, `SacTableService`, `SacDataSourceService`, a widget integration spec (`sac-widget-integration.spec.ts`, 9.7 KB — the largest file), and a table integration spec. Vitest resolves entry point aliases through the `resolve.alias` map in `vitest.config.ts`, pointing each `@sap-oss/sac-webcomponents-ngx/*` import directly at the library source TypeScript, meaning tests run against source rather than built output.

Playwright is used for a different testing tier: `verify:widget-harness` runs a browser-level smoke test against the built IIFE widget bundle, validating that the widget registers as a custom element and renders without JavaScript errors in a real browser context. This two-tier strategy — Vitest for unit and integration, Playwright for widget build smoke — is enforced by the `release:check` script, which runs both gates before a release is considered valid.

The CI pipeline is defined at `.github/workflows/ci-sac-ai-widget.yml` and runs the same sequence as `release:check`: lint, test, build, widget build, `verify:pack`, and `package`.

---

## Security Posture

Bearer token handling is the primary security-sensitive surface. The `SACRestAPIClient` supports both static token injection and a `getAuthToken` callback for dynamic resolution. In the Angular tier, `SacAuthService` is the singleton token store; it receives the SAC session bearer token via `setToken()` at widget lifecycle update time. The token is forwarded on each outbound request in the `Authorization` header and on each AG-UI SSE stream request. The token is not written to `localStorage` or any persistent store within this codebase; it lives only in memory for the lifetime of the Angular application instance.

The `sacBearerToken` property in `widget.json` is described as "injected at runtime by SAC," which is the standard SAC mechanism for providing session credentials to custom widgets through the Designer properties system. This is the expected pattern for SAC custom widgets and does not represent a credential-management deviation.

The Shadow DOM attachment in the widget entry (`attachShadow({ mode: 'open' })`) provides style isolation but not security isolation; open shadow roots are accessible to the host page's JavaScript. This is the norm for SAC custom widgets and is consistent with the SAC custom widget specification.

The `ignoreIntegrity: true` flag on the widget web component declaration in `widget.json` disables subresource integrity checking for the widget JavaScript bundle. This is an operational trade-off that simplifies local and iterative deployment at the cost of bundle integrity verification. For production deployments, SAC engineering should evaluate setting this to `false` and populating the `integrity` field with an SHA-256 hash of the built `widget.js` as part of the release pipeline.

---

## Integration Topology

At runtime, the SAC AI Widget participates in a three-node integration topology. The SAC tenant is the host: it provides the Designer runtime, the datasource model, and the session bearer token. The CAP LLM Plugin backend (a Cloud Foundry application on BTP) is the AI agent backend: it receives AG-UI run requests, drives an LLM, and streams structured AG-UI events back. The widget itself is the integration fabric between the two: it holds the SAC session token, forwards it to the CAP backend on each SSE request, and translates LLM tool calls into live mutations of the SAC data widget state.

The `capBackendUrl` and `tenantUrl` designer properties are the two configuration seams that an operator must supply to wire this topology. The `modelId` determines which SAC datasource model the widget presents and provides as context to the LLM. No service mesh, sidecar, or additional infrastructure is required beyond a reachable CAP LLM Plugin deployment.

---

## Assessment Summary

`@sap-oss/sac-webcomponents-ngx` is a well-structured, purposefully scoped library with a coherent dual-output model: Angular component libraries for application integrators and an AI-enabled custom widget for SAC Designer users. The build pipeline is robust, with deterministic entry point verification, package dry-run gating, and a Playwright browser smoke harness that prevents silently broken widget releases. The Angular entry points follow current Angular best practices (FESM2022, `ng-packagr`, `forRoot`/`forChild` module patterns, standalone-compatible component exports). The SDK is cleanly separated from Angular, enabling non-Angular consumers. The Mangle Datalog specifications represent an unconventional but principled approach to keeping the component API surface aligned with the upstream SAC domain model.

The primary areas that warrant further attention before any production deployment are: confirming the Mangle code generation pipeline is fully automated and not partially hand-edited, evaluating re-enabling SRI (`ignoreIntegrity: false`) for widget bundle integrity assurance in production, and reviewing whether `HttpClientModule` (imported in `SacCoreModule`, deprecated in Angular 17+ in favour of `provideHttpClient()`) should be migrated before the Angular dependency range reaches Angular 18+.
