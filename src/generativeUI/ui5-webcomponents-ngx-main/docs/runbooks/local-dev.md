# Local Development Runbook

## Prerequisites

| Tool | Min version |
|------|-------------|
| Node.js | 20 LTS |
| npm | 10 |
| Python | 3.11 |
| uv (Python pkg manager) | 0.4+ |
| nx (global optional) | 22 |

---

## 1. Install dependencies

```bash
# JS/Angular monorepo
npm ci

# Python agent
cd agent
uv sync
```

---

## 2. Start the agent backend

```bash
cd agent
uv run uvicorn ui5_ngx_agent:app --reload --port 8080
```

The agent exposes:
- `POST /ag-ui/run` — AG-UI SSE stream endpoint consumed by `<joule-chat>`
- `GET  /health`    — liveness probe

Required env vars (copy `.env.example` → `.env`):

| Variable | Description |
|----------|-------------|
| `AICORE_AUTH_URL` | SAP AI Core OAuth2 token URL |
| `AICORE_CLIENT_ID` | AI Core client ID |
| `AICORE_CLIENT_SECRET` | AI Core client secret |
| `AICORE_BASE_URL` | AI Core inference base URL |
| `MCP_SERVER_BEARER_TOKEN` | Bearer token for MCP server auth middleware |
| `HANA_BASE_URL` | (Optional) HANA Cloud REST SQL for audit log |
| `HANA_CLIENT_ID` | (Optional) |
| `HANA_CLIENT_SECRET` | (Optional) |
| `HANA_AUTH_URL` | (Optional) |

For local dev without SAP AI Core, set `USE_LOCAL_OLLAMA=true` and have Ollama running on `localhost:11434`.

---

## 3. Start the Angular dev server

```bash
npx nx serve playground
```

The webpack dev server starts on **http://localhost:4200**.  
`proxy.conf.json` forwards `/ag-ui/*` → `http://localhost:8080`.

Navigate to **http://localhost:4200/joule** to open the Joule AI panel.

---

## 4. Run unit tests

```bash
# All libraries
npx nx run-many --target=test --all

# Single library
npx nx test ag-ui-angular
npx nx test genui-renderer
npx nx test genui-streaming
npx nx test genui-governance
```

---

## 5. Run E2E tests

E2E tests require the Angular dev server to be running (handled automatically by Cypress's `devServerTarget`):

```bash
# Headless (CI)
npx nx e2e playground-e2e --configuration=ci

# Interactive
npx nx e2e playground-e2e --watch
```

---

## 6. Storybook

```bash
npx nx storybook ag-ui-angular
npx nx storybook genui-renderer
```

---

## 7. Linting

```bash
npx nx run-many --target=lint --all
```

---

## 8. Troubleshooting

**`/ag-ui/run` returns 502**  
→ Agent backend not running. Start uvicorn (step 2).

**`Cannot find module '@ui5/ag-ui-angular'` in IDE**  
→ Pre-existing IDE artifact; `npm ci` + IDE reload resolves it. The monorepo uses TypeScript path aliases in `tsconfig.base.json`, not installed packages.

**Cypress `cy.interceptAgUi` not found**  
→ Ensure `apps/playground-e2e/src/support/e2e.ts` is listed as `supportFile` in `cypress.config.ts`. The `commands.ts` import chain handles registration.

**`AICORE_AUTH_URL` SSRF guard error on startup**  
→ The agent validates all env-var URLs at import time. Ensure the URL uses `https://` and does not target `169.254.*` (cloud metadata) prefixes.
