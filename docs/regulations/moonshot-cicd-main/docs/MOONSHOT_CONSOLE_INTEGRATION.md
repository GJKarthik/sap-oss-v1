# Process Check UI Integration (Angular/UI5)

This repository replaces the Streamlit Process Check runtime with the UI5 Angular `moonshot-console` app.

## Where It Lives

- Angular source of truth in Moonshot app: `process_check_app/frontend/moonshot_console_src/`
- Build workspace app path: `sdk/sap-sdk/sap-ui5-webcomponents-ngx/apps/moonshot-console`
- Static app root (served directly): `process_check_app/index.html`
- Angular bundle target: `process_check_app/assets/moonshot_console/`

## Sync the UI into Process Check

```bash
cd /Users/user/Documents/sap-ai-suite/regulations/moonshot-cicd-main
./scripts/sync_moonshot_console_ui.sh
```

The script syncs the Moonshot source tree into the UI5/Nx workspace, builds `moonshot-console` for subpath hosting, then syncs output back into Process Check assets.

## Run Backend Services

Start Fabric Moonshot gateway:

```bash
cd /Users/user/Documents/sap-ai-suite/src/data/ai-core-fabric/zig
zig build run
```

Start OData persistence service:

```bash
cd /Users/user/Documents/sap-ai-suite/src/data/ai-core-odata/zig
zig build run
```

Optional PAL service (if your deployment uses it):

```bash
cd /Users/user/Documents/sap-ai-suite/src/data/ai-core-pal/zig
zig build run
```

HANA persistence is configured via OData environment variables used by other services (`HANA_HOST`, `HANA_PORT`, `HANA_USER`, `HANA_PASSWORD`, `HANA_SCHEMA`).

## Run Process Check UI

```bash
cd /Users/user/Documents/sap-ai-suite/regulations/moonshot-cicd-main
./scripts/serve_process_check_ui.sh
```

Then open `http://localhost:8000` (redirects to `#/welcome`).

## Ports and URLs

- Static asset server port: `PROCESS_CHECK_HTTP_PORT` (default `8000`)
- Fabric gateway default expected by UI: `http://localhost:8088`
- Fabric service bind port override: `FABRIC_PORT` (for example `18088`)
- OData service default in Fabric integration: `http://127.0.0.1:9882`

If you run Fabric on a non-default port, update Moonshot Console Settings in the UI and set **Backend URL** to match (for example `http://localhost:18088`).

## Legacy Note

Legacy Streamlit runtime files and tests have been removed. Deployment/runtime entrypoints are Angular/UI5 static serving (`process_check_app/index.html`, `scripts/serve_process_check_ui.sh`, `Dockerfile_PC`).
