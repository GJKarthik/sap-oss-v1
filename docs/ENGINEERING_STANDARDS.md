# Engineering Standards and Repository Map

This document defines the minimum quality baseline for all active subprojects in this repository and provides a map of projects, ownership, and CI.

## Mandatory Standards (per subproject)

Each active subproject must satisfy:

1. **Security**
   - No plaintext credentials in version control; use `.env.example` templates and keep `.env` in `.gitignore`.
   - CORS must use an allowlist (e.g. `CORS_ALLOWED_ORIGINS`); no wildcard origin with credentials in production.
   - Run dependency and, where applicable, code security scans (e.g. Snyk, `npm audit`, `pip-audit`).

2. **CI**
   - On every PR: lint and unit (or integration) tests must run.
   - Coverage must be collected and reported; minimum thresholds are defined per project (see coverage config or CI workflow).
   - Dependency vulnerability checks run in CI (Dependabot and/or Snyk).

3. **Testing**
   - E2E retries should be minimal (e.g. 1 retry); flaky tests should be fixed rather than masked.
   - New first-party code should be covered by Snyk (or equivalent) when the workspace rule applies.

## Repository Map

| Project | Purpose | Language / Stack | CI Location | Notes |
|--------|---------|------------------|-------------|--------|
| **ai-sdk-js-main** | SAP Cloud SDK for AI (JS/TS) | TypeScript, pnpm, Jest | `.github/workflows/ci-ai-sdk-js.yml` | Monorepo; coverage threshold in `jest.config.mjs`. |
| **ai-core-pal** | AI Core PAL | Zig | — | See project README. |
| **ai-core-streaming** | AI Core streaming | Zig, Mojo, Mangle | `ai-core-streaming/.github/workflows/e2e-tests.yml` | Unit, integration, performance, security. |
| **cap-llm-plugin-main** | CAP LLM Plugin | TypeScript, Node, Jest | `cap-llm-plugin-main/.github/workflows/ci.yml`, `e2e.yml` | Coverage threshold 70% in `jest.config.js`. |
| **data-cleaning-copilot-main** | Data cleaning tool | Python, FastAPI, Gradio | `.github/workflows/ci-data-cleaning-copilot.yml` | Pytest + coverage for `definition/odata`. |
| **elasticsearch-main** | Elasticsearch integration | Java, Gradle | — | See AGENTS.md and CONTRIBUTING. |
| **generative-ai-toolkit-for-sap-hana-cloud-main** | HANA AI toolkit | Python | — | MCP server; CORS via `CORS_ALLOWED_ORIGINS`. |
| **langchain-integration-for-sap-hana-cloud-main** | LangChain + HANA | Python | — | MCP server; CORS via `CORS_ALLOWED_ORIGINS`. |
| **mangle-main** | Mangle logic language | Go, Rust | — | See project CONTRIBUTING. |
| **mangle-query-service** | Mangle query service | Go, gRPC, Elasticsearch | — | See project README. |
| **odata-vocabularies-main** | OData vocabularies | Python | `odata-vocabularies-main/.github/workflows/ci.yml` | Pytest, Codecov, coverage fail-under. |
| **ui5-webcomponents-ngx-main** | UI5 Angular components | Angular, Nx, TypeScript | — | Jest; MCP server CORS via env. |
| **vllm-main** | vLLM inference engine | Python, PyTorch | — | Large test suite; MCP server CORS via env. |
| **world-monitor-main** | World Monitor dashboard | TypeScript, Vite, Tauri, Playwright | `.github/workflows/ci-world-monitor.yml` | Typecheck, unit, E2E runtime. |

## Shared Configuration

- **Root `.gitignore`**: Excludes `.env`, `.env.local`, and common secret patterns.
- **Dependabot**: `.github/dependabot.yml` configures weekly updates for npm/pip and GitHub Actions across projects.
- **Snyk**: `.github/workflows/snyk.yml` runs dependency and code scanning when `SNYK_TOKEN` is set; see [SECURITY.md](../SECURITY.md).
- **CORS**: All first-party API and MCP servers use `CORS_ALLOWED_ORIGINS` (comma-separated); default includes `http://localhost:3000`, `http://127.0.0.1:3000`.

## Onboarding

- Before contributing, run lint and tests locally (see each project’s README or CONTRIBUTING).
- New services or APIs: add CORS allowlist and never commit secrets; add or extend CI if the project is active.
- When adding first-party code, run the project’s security/code scan (e.g. Snyk) and address findings.
