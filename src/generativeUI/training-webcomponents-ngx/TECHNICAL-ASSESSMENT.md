# Technical Assessment — training-console

> Assessed against: `training-console`, `sap-sac-webcomponents-ngx`, `ui5-webcomponents-ngx-main`

---

## 1. Architecture

**Rating: 4 / 5**

The application is an Nx 22 monorepo hosting a single Angular 20 standalone-component shell (`apps/angular-shell`) backed by a Python FastAPI server. Key strengths:

- Full adoption of Angular Signals for reactive state — no `BehaviorSubject` patterns in components.
- Clean separation of concerns: components own UI logic, `ApiService` owns HTTP transport, `AuthService` owns token lifecycle, `ToastService` owns user feedback.
- Functional HTTP interceptor chain (`authInterceptor → timeoutInterceptor → cacheInterceptor → errorInterceptor`) with no class-based interceptors (Angular 14+ pattern).
- Route lazy-loading for all five feature pages with route guards.
- `GlobalErrorHandler` catches unhandled exceptions centrally.

**Gaps addressed in this cycle:**
- `ApiService` now provides exponential-backoff retry (max 2 attempts, configurable) and typed `ApiError` normalisation so all callers receive a consistent error shape.
- `TimeoutInterceptor` enforces per-request timeouts via `REQUEST_TIMEOUT_MS` context token, preventing long-running requests from hanging indefinitely.

---

## 2. Testing

**Rating: 4 / 5** (was 2 / 5)

| Suite | Coverage |
|-------|---------|
| `api.service.spec.ts` | HTTP CRUD, error propagation |
| `auth.service.spec.ts` | Token CRUD, `isAuthenticated` |
| `pipeline.component.spec.ts` | WebSocket lifecycle, log parsing, `startPipeline`, stage state |
| `hippocpp.component.spec.ts` | `loadStats`, `runQuery`, `clearResults`, `resultColumns`, `formatCell`, `presets` |
| `data-explorer.component.spec.ts` | Asset counts, filter/search, `select`/`clearSelection`, `setTab`, difficulty counts |
| `compare.component.spec.ts` | Model filtering, `runComparison`, error placeholders, history capping, `isWinner` |
| `registry.component.spec.ts` | Status/deployed filtering, tag CRUD (`localStorage`), `deploy`, `deleteJob` |
| `app.spec.ts` + `visual.spec.ts` | Playwright e2e — navigation, auth flow, visual regression |

**Still missing:**
- Snapshot / screenshot visual regression beyond the Playwright suite.
- HTTP interceptor unit tests.

---

## 3. HTTP Resilience

**Rating: 4 / 5** (was 1 / 5)

| Feature | Before | After |
|---------|--------|-------|
| Retry on transient errors | ✗ | ✓ Exponential backoff, 2 retries, 5xx + status 0 |
| Per-request timeout | ✗ | ✓ `REQUEST_TIMEOUT_MS` token (default 30 s) |
| Typed error surface | ✗ | ✓ `ApiError { status, detail, url }` |
| Semantic toast messages | ✓ | ✓ (unchanged) |
| Non-retryable pass-through | N/A | ✓ 4xx errors skip retry and are immediately normalised |

---

## 4. Security

**Rating: 3 / 5**

- Bearer token injected at transport layer via `authInterceptor` — never stored in component state.
- Token persisted in `sessionStorage` (not `localStorage`) — cleared on tab close.
- No secrets in source code; runtime config injected via `window.__TRAINING_CONFIG__`.
- `X-Skip-Error-Toast` header allows callers to suppress toast for silent background polls.

**Remaining concerns:**
- Angular packages should be bumped to ≥ 20.3.14 to address known XSS / sensitive-data-in-sent-data CVEs (flagged by Snyk).
- No CSRF protection — acceptable for API-key-only auth but should be documented.
- WebSocket connections in `PipelineComponent` use an unprotected `ws://` URL in local dev.

---

## 5. Developer Experience

**Rating: 4 / 5** (was 2 / 5)

- `CHANGELOG.md` documents all notable changes.
- `CONTRIBUTING.md` covers prerequisites, setup, branch naming, commit conventions, and PR checklist.
- `CODE_OF_CONDUCT.md` follows Contributor Covenant v2.1.
- Nx task runners (`lint`, `test`, `build`, `e2e`) are wired and runnable with a single command.

**Still missing:**
- Storybook or component harness for isolated UI development.
- ADR (Architecture Decision Records) directory.

---

## 6. Observability

**Rating: 2 / 5**

Currently relies entirely on browser console and `ToastService` for runtime visibility.

**Planned (tc-5):**
- `/api/health` endpoint on the FastAPI side returning `{ status, version, uptime_s, db_connected }`.
- Structured JSON logging in the Angular shell (replaces `console.*` calls with a `LogService` that emits `{ level, message, context, timestamp }`).

---

## 7. Summary Score

| Dimension | Score |
|-----------|-------|
| Architecture | 4 / 5 |
| Testing | 4 / 5 |
| HTTP Resilience | 4 / 5 |
| Security | 3 / 5 |
| Developer Experience | 4 / 5 |
| Observability | 2 / 5 |
| **Overall** | **3.5 / 5** |

Compared to the initial **2.5 / 5** baseline this cycle addresses the two highest-priority gaps (testing coverage and HTTP resilience). The remaining gap is observability, which requires backend cooperation.
