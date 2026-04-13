# Gateway

Edge layer for the generativeUI suite. Consists of an **nginx reverse proxy**, a **FastAPI health aggregator**, and static **placeholder pages**.

## Components

| Path | Role |
|------|------|
| `nginx.conf.template` | nginx config with env-var substitution for upstream routing |
| `health/` | FastAPI service that polls upstream health endpoints and reports aggregate status |
| `placeholders/ui5/` | Static stub page served when the UI5 workspace is not deployed |

## Running

The gateway is started via the root `docker-compose.yml` as the `suite-gateway` service. It is not intended to run standalone.

End-to-end operational checklist (secrets, compose, smoke tests, UI5 E2E): [docs/runbooks/operationalize-apps.md](../../../docs/runbooks/operationalize-apps.md).

```bash
# From src/generativeUI/
docker compose up suite-gateway
```

## Health Aggregator

The `health/` directory contains a minimal FastAPI app (`main.py`) that:
- Accepts a list of upstream health URLs via environment variables.
- Polls each URL periodically.
- Exposes `/health` returning the aggregate result.

### Dependencies

See `health/requirements.txt`: FastAPI, uvicorn, httpx.

## AG-UI proxy

The `location /ag-ui/` block forwards the client `Authorization` header to the upstream agent/MCP (`proxy_set_header Authorization $http_authorization`). SSE uses `proxy_buffering off`, `proxy_read_timeout 600s`, and chunked encoding so streams flush immediately (same idea as BTP/nginx in [deploy.md](../ui5-webcomponents-ngx-main/docs/runbooks/deploy.md)).

## API path map (canonical + legacy)

Use these paths from the browser when the workspace is served behind this gateway. The Angular production build ([`environment.prod.ts`](../ui5-webcomponents-ngx-main/apps/workspace/src/environments/environment.prod.ts)) targets the **canonical** `/api/v1/*` rows.

| Purpose | Canonical path | Upstream | Legacy alias |
|--------|-----------------|----------|--------------|
| Training / OpenAI-compat / audit / notifications / auth | `/api/v1/training/*` | `training_api:8000` | `/api/training/*` |
| OpenAI-style routes (same server) | `/api/v1/ui5/openai/*` | `training_api:8000` | `/api/openai/*` |
| MCP + AG-UI (see `/ag-ui/`) | `/api/v1/ui5/mcp/*` | `ui5_mcp:9160` | `/api/mcp/*` |
| PAL (AI Core PAL upstream) | `/api/v1/ui5/pal/*` | `${AI_CORE_PAL_UPSTREAM}` | — |
| Workspace `mcpBaseUrl` | End with `/mcp` (e.g. `/api/v1/ui5/mcp/mcp`) | — | — |

The training API also exposes **`GET /capabilities`** (proxied as `/api/v1/training/capabilities`) for structured stack readiness (database, HANA vector, vLLM, AI Core, optional PAL upstream).

Smoke checks: [`scripts/smoke-public-paths.sh`](scripts/smoke-public-paths.sh) (set `GATEWAY_URL`). See [deploy.md](../ui5-webcomponents-ngx-main/docs/runbooks/deploy.md) section **9**.

How this fits broader verification: PR CI runs workspace **unit** tests only; **E2E + compose + this smoke script** are documented in [workspace README](../ui5-webcomponents-ngx-main/apps/workspace/README.md#testing) and [.github/workflows/ci-workspace-integration.yml](../../../.github/workflows/ci-workspace-integration.yml).

Local `nx serve` still uses absolute `http://localhost:*` URLs in [`environment.ts`](../ui5-webcomponents-ngx-main/apps/workspace/src/environments/environment.ts); [`proxy.conf.js`](../ui5-webcomponents-ngx-main/apps/workspace/proxy.conf.js) rewrites `/api/training` and `/api/v1/training`, `/api/v1/ui5/openai`, and `/api/v1/ui5/mcp` for path-based testing.

BTP **Application Router** templates (destinations, SSE/WS routes) live in [`btp/`](btp/README.md); see [deploy.md](../ui5-webcomponents-ngx-main/docs/runbooks/deploy.md) section **3b**.
