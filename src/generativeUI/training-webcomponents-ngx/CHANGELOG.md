# Changelog

All notable changes to the **training-webcomponents-ngx** are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Component specs for `PipelineComponent`, `HippocppComponent`, `DataExplorerComponent`, `CompareComponent`, `RegistryComponent`
- `ApiService` hardening: exponential-backoff retry (max 2 attempts) for 5xx / network errors, typed `ApiError` class, `REQUEST_TIMEOUT_MS` context token
- `TimeoutInterceptor` — enforces per-request timeout via `REQUEST_TIMEOUT_MS`; converts `TimeoutError` to a normalised `HttpErrorResponse(status=0)`
- `CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `TECHNICAL-ASSESSMENT.md`

---

## [1.0.0] — 2024-03-01

### Added
- Initial Nx 22 / Angular 20 monorepo scaffold with standalone component architecture
- `PipelineComponent` — WebSocket live-log streaming for the Zig data-generation pipeline, 7-stage progress tracker, per-line colour coding
- `HippocppComponent` — HippoCPP graph-database stats dashboard and Cypher query sandbox with preset library
- `DataExplorerComponent` — tabbed browser for 16 static data assets and dynamically loaded SQL training pairs, with filtering by category and difficulty
- `CompareComponent` — side-by-side A/B model comparison with capped 10-entry history and result-length winner indicator
- `RegistryComponent` — model registry with tag persistence (`localStorage`), one-click deploy / delete, and status / deployed-only filters
- `ApiService` — base HTTP wrapper (`get`, `post`, `delete`)
- `AuthInterceptor`, `CacheInterceptor`, `ErrorInterceptor` — bearer token injection, in-memory GET caching, and semantic HTTP error toasts
- `GlobalErrorHandler` — catches unhandled runtime exceptions and surfaces them via `ToastService`
- `AuthService` — `sessionStorage`-backed API-key management with `__TRAINING_CONFIG__` runtime injection
- `ToastService` — success / warning / error / info toast variants
- Playwright e2e suite (`app.spec.ts`, `visual.spec.ts`) covering critical user journeys
- `ApiService` unit tests via `HttpClientTestingModule`
- `AuthService` unit tests
