# BTP approuter (HTML5 + API destinations)

Templates for deploying the UI5 **workspace** behind SAP BTP **Application Router** with **destinations** pointing at the same logical backends as [nginx.conf.template](../nginx.conf.template).

## Files

| File | Purpose |
|------|---------|
| [`xs-app.json`](xs-app.json) | Route table: static UI, `/api/v1/*`, `/ag-ui/`, WebSocket `/collab/` |
| [`default-env.json.template`](default-env.json.template) | Copy to `default-env.json` locally; in CF use destination service bindings instead |

## Destinations (CF / BTP)

Create destinations (or MTA `requires`) with these names, adjusted to your landscape:

| Name | Example URL | Notes |
|------|-------------|--------|
| `training_api` | `https://<training-app>.cfapps...` | FastAPI training console |
| `ui5_mcp` | `https://<mcp-or-agent>.cfapps...` | Port 9160-style MCP / AG-UI host |
| `pal_upstream` | `https://<ai-core-pal-proxy>...` | Same target as gateway `AI_CORE_PAL_UPSTREAM` |

## SSE and WebSocket

- **SSE (`/ag-ui/`)**: Configure the approuter’s upstream (or an additional reverse proxy in front) with **no buffering** and long read timeout, as in [deploy.md](../../ui5-webcomponents-ngx-main/docs/runbooks/deploy.md) (nginx `proxy_buffering off`, `proxy_read_timeout 600s`). The managed approuter may still buffer; validate streaming in your target region or place nginx between router and MCP.
- **WebSocket (`/collab/`)**: Enable WebSocket forwarding on the route to `ui5_mcp` (see `xs-app.json`).

## Auth

- With **XSUAA**, the approuter injects user JWT; forward `Authorization` to `training_api` and MCP so [identity.py](../../training-webcomponents-ngx/packages/api-server/src/identity.py) can resolve the user from bearer tokens.
- Align with [deploy.md](../../ui5-webcomponents-ngx-main/docs/runbooks/deploy.md) for agent env vars (`AICORE_*`, `HANA_*`, `MCP_SERVER_BEARER_TOKEN`).
- HANA **hdbcli vs REST SQL** split: [ADR 004](../../ui5-webcomponents-ngx-main/docs/adr/adr-004-hana-pal-gateway.md) and deploy.md section **8**.

## Angular build

Build the workspace with production `environment.prod.ts` (canonical `/api/v1/*` paths). Deploy the `dist/apps/workspace` static files as the HTML5 application consumed by this router.
