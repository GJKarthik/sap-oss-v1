# Moonshot Console

UI5 Angular console for running Moonshot Zig tests through AI Core Fabric.

## Features

- Config summary screen from `/api/moonshot/config/summary`
- Connector + test-config catalog from `/api/moonshot/test-configs`
- Run trigger form that calls `POST /api/moonshot/runs`
- Run history screen from `/api/moonshot/runs`
- Typed API service with mock fallback for offline usage

## Start UI

```bash
cd sdk/sap-sdk/sap-ui5-webcomponents-ngx
nx serve moonshot-console
```

## Backend Wiring

The UI expects AI Core Fabric to expose Moonshot gateway endpoints.

```bash
cd src/data/ai-core-fabric/zig
zig build run
```

Optional environment variables for Fabric -> Moonshot integration:

- `MOONSHOT_ROOT` (default autodetects `regulations/moonshot-cicd-main`)
- `MOONSHOT_ZIG_BIN` (override Moonshot Zig binary path)
- `MOONSHOT_ODATA_URL` (default `http://127.0.0.1:9882`)
- `MS_CONFIG_PATH` (Moonshot config file, default `moonshot_config.yaml`)
- `MS_TEST_CONFIG_PATH` (Moonshot tests file, default fallback chain)

For OData run persistence service:

```bash
cd src/data/ai-core-odata/zig
zig build run
```

Moonshot run persistence endpoint paths used by Fabric:

- `GET /api/moonshot/health`
- `GET /api/moonshot/runs`
- `POST /api/moonshot/runs`
- `GET /api/moonshot/runs/{run_id}`

HANA-like persistence support in OData store is controlled by:

- `HANA_HOST`
- `HANA_PORT`
- `HANA_USER`
- `HANA_PASSWORD`
- `HANA_SCHEMA`

When backend endpoints are not reachable, the UI uses mock fallback responses if enabled in Settings.
