# Deployment Runbook

## Target platform: SAP BTP Cloud Foundry

---

## 1. Build

```bash
# Production Angular build
npx nx build workspace --configuration=production
# Output: dist/apps/workspace/
```

---

## 2. Agent backend

The Python agent is deployed as a **separate CF application** alongside the Angular app.

```bash
cd agent
cf push ui5-ngx-agent \
  --buildpack python_buildpack \
  --command "uvicorn ui5_ngx_agent:app --host 0.0.0.0 --port 8080" \
  --memory 512M \
  --instances 2
```

Set the following CF environment variables (never commit to source):

```bash
cf set-env ui5-ngx-agent AICORE_AUTH_URL        "https://..."
cf set-env ui5-ngx-agent AICORE_CLIENT_ID       "..."
cf set-env ui5-ngx-agent AICORE_CLIENT_SECRET   "..."
cf set-env ui5-ngx-agent AICORE_BASE_URL        "https://..."
cf set-env ui5-ngx-agent MCP_SERVER_BEARER_TOKEN "..."
cf set-env ui5-ngx-agent HANA_BASE_URL          "https://..."
cf set-env ui5-ngx-agent HANA_CLIENT_ID         "..."
cf set-env ui5-ngx-agent HANA_CLIENT_SECRET     "..."
cf set-env ui5-ngx-agent HANA_AUTH_URL          "https://..."
cf restage ui5-ngx-agent
```

---

## 3. Angular app (static hosting via nginx)

```bash
cf push ui5-ngx-frontend \
  --buildpack staticfile_buildpack \
  -p dist/apps/workspace \
  --memory 64M
```

The `nginx.conf` at the repo root must be copied into `dist/apps/workspace/` before push, or referenced via a `Staticfile` with `root: .`.

### Critical nginx directives for SSE

```nginx
location /ag-ui/ {
    proxy_pass         http://ui5-ngx-agent.internal:8080;
    proxy_http_version 1.1;
    proxy_set_header   Connection '';          # Disable keep-alive upgrade
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_buffering    off;                    # Required for SSE
    proxy_cache        off;
    proxy_read_timeout 600s;
    chunked_transfer_encoding on;
}
```

Without `proxy_buffering off`, nginx buffers the SSE response and the Angular client never receives events until the stream closes.

---

## 3b. BTP Application Router (alternative edge)

For **XSUAA + destinations** instead of staticfile/nginx, use the templates under [`gateway/btp`](../../../gateway/btp/README.md):

- [`xs-app.json`](../../../gateway/btp/xs-app.json) — routes for `/api/v1/training/`, `/api/v1/ui5/openai/`, `/api/v1/ui5/mcp/`, `/api/v1/ui5/pal/`, `/ag-ui/`, and WebSocket `/collab/`
- [`default-env.json.template`](../../../gateway/btp/default-env.json.template) — local destination names; in CF bind the **Destination** service and define `training_api`, `ui5_mcp`, `pal_upstream`

SSE buffering: validate streaming end-to-end; if the router buffers, add nginx in front of the MCP host or follow SAP notes for your `@sap/approuter` version. The nginx snippet above remains the reference behavior.

---

## 4. nx.json Cloud token

`NX_CLOUD_ACCESS_TOKEN` must be set as a CI/CD secret — never in `nx.json`.  
See `.github/workflows/ci-*.yml` for the secret reference pattern.

---

## 5. CI pipeline

Each PR triggers the workspace CI workflow (adapt as needed):

1. `npm ci`
2. `npx nx run-many --target=lint --all`
3. `npx nx run-many --target=test --all`
4. `npx nx build workspace --configuration=production`
5. `npx nx e2e workspace-e2e --configuration=ci`

---

## 6. Rollback

```bash
# Roll back agent to previous version
cf rollback ui5-ngx-agent --version <N>

# Roll back frontend
cf rollback ui5-ngx-frontend --version <N>
```

---

## 7. Health checks

| Endpoint | Expected |
|----------|----------|
| `GET /health` (agent) | `200 {"status":"ok"}` |
| `GET /` (frontend) | `200` HTML |
| `POST /ag-ui/run` with empty body | `400` or `422` |

The last check verifies the agent rejects unauthenticated/malformed requests before returning any SSE data.

---

## 8. HANA: hdbcli vs REST SQL

- **Training API** (FastAPI): prefers **hdbcli** via SQLAlchemy / `DATABASE_URL` or `HANA_*` — see [ADR 004: HANA connectivity and PAL](../adr/adr-004-hana-pal-gateway.md).
- **Agent / MCP**: may use **REST SQL** with OAuth (`HANA_BASE_URL`, `HANA_AUTH_URL`, `HANA_CLIENT_ID`, `HANA_CLIENT_SECRET`) as in section 2 above.

Use service bindings for HANA Cloud in both cases; align variable names per app.

---

## 9. BTP / gateway smoke checklist

After deploy (nginx gateway, compose, or approuter):

1. **Training API**: `GET …/api/v1/training/health` and `GET …/api/v1/training/capabilities` return JSON (200). Legacy alias `GET …/api/training/health` should match if enabled.
2. **OpenAI-compat**: `GET …/api/v1/ui5/openai/health` (or training `/health` if shared) responds.
3. **MCP**: `GET …/api/v1/ui5/mcp/health` (path may vary by mount) returns 200/401 as configured.
4. **SSE**: open a client against `/ag-ui/run` (or your streamed route); confirm chunks arrive without long buffering (nginx `proxy_buffering off` or approuter equivalent).
5. **WebSocket**: `wss://…/collab/…` connects when collab is enabled.
6. **Destinations** (approuter): `training_api`, `ui5_mcp`, and `pal_upstream` resolve and forward `Authorization` where required.

Repo script (optional, against a running gateway URL):

```bash
GATEWAY_URL=http://localhost:8080 bash ../../../gateway/scripts/smoke-public-paths.sh
```
