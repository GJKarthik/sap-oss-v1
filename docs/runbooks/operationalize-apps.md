# Operationalize and use the SAP OSS apps

This runbook implements the operational checklist for the repository: choose a runtime, configure secrets, bring stacks up, verify health, enable production auth, and optionally run UI5 workspace E2E with live backends.

## 1. Choose your runtime

| Goal | Entry point | Documentation |
|------|-------------|----------------|
| Full platform (training shell + api-server + vLLM + HANA/AI Core secrets) | [docker-compose.yml](../../docker-compose.yml) | This doc, section 2–3 |
| generativeUI suite gateway (training + UI5 + MCP on one nginx, default port **8080**) | [src/generativeUI/docker-compose.yml](../../src/generativeUI/docker-compose.yml) | [Gateway README](../../src/generativeUI/gateway/README.md) |
| Training workbench only (dev) | Nx + optional FastAPI | [training-webcomponents-ngx README](../../src/generativeUI/training-webcomponents-ngx/README.md) |
| Training on Kyma | Kubernetes manifests | [deploy/kyma/README.md](../../src/generativeUI/training-webcomponents-ngx/deploy/kyma/README.md) |
| UI5 workspace on BTP / CF | Static + agent or approuter | [deploy.md](../../src/generativeUI/ui5-webcomponents-ngx-main/docs/runbooks/deploy.md), [gateway/btp](../../src/generativeUI/gateway/btp/README.md) |

Use **one** primary compose stack at a time unless you intentionally map different ports to avoid conflicts (e.g. platform uses **80**, suite gateway uses **8080**).

## 2. Environment and secrets (root platform)

1. Bootstrap local files (optional helper):

   ```bash
   bash scripts/operationalize/bootstrap-local-env.sh
   ```

   This creates `.env` from [.env.example](../../.env.example) and copies secret **placeholders** into `.secrets/` from [.secrets.example](../../.secrets.example). Replace every placeholder with real values before production.

2. Edit `.env`: set `HANA_HOST`, `AICORE_AUTH_URL`, `AICORE_BASE_URL`, and ensure `*_FILE_SOURCE` paths point at your `.secrets/` files (the bootstrap script rewrites `.secrets.example` → `.secrets` in `.env`).

3. Training API server (standalone or suite) env template: [packages/api-server/.env.example](../../src/generativeUI/training-webcomponents-ngx/packages/api-server/.env.example) (`MODELOPT_URL`, `ALLOWED_ORIGINS`, HANA, AI Core).

4. generativeUI-wide optional vars: [src/generativeUI/.env.example](../../src/generativeUI/.env.example) (`SUITE_GATEWAY_PORT`, PAL upstreams, optional health URLs).

## 3. Bring up and verify

Validate Compose files without starting containers:

```bash
bash scripts/operationalize/verify-composes.sh
```

### Root platform

```bash
docker compose -f docker-compose.yml up -d --build
```

Check service health in Docker Desktop or `docker compose ps`. The `api-server` healthcheck calls `/health` on port 8002.

### generativeUI suite

```bash
docker compose -f src/generativeUI/docker-compose.yml up -d --build
```

Smoke public API paths (default gateway **8080**):

```bash
GATEWAY_URL=http://localhost:8080 bash scripts/operationalize/smoke-suite-gateway.sh
```

Or use the upstream script: `src/generativeUI/gateway/scripts/smoke-public-paths.sh`.

## 4. Production browser auth (training shell)

Runtime auth is controlled by `window.__TRAINING_CONFIG__` (see [training README](../../src/generativeUI/training-webcomponents-ngx/README.md)). For internet-facing deployments, use **`authMode: 'edge'`** and terminate OIDC at an edge proxy (IAS/XSUAA, oauth2-proxy, etc.).

Reference implementations:

- Kyma: [training-edge-auth-overlay.yaml](../../src/generativeUI/training-webcomponents-ngx/deploy/kyma/training-edge-auth-overlay.yaml) (ConfigMap `runtime-config.js` + oauth2-proxy).
- Example snippet for custom hosting: [training-config-edge.example.js](../../src/generativeUI/training-webcomponents-ngx/deploy/kyma/training-config-edge.example.js).

BTP Application Router routes: [gateway/btp/README.md](../../src/generativeUI/gateway/btp/README.md).

## 5. UI5 workspace + live backends + E2E

1. Start APIs on the host (overlay publishes ports **8000** and **9160**):

   ```bash
   docker compose -f src/generativeUI/docker-compose.yml \
     -f src/generativeUI/docker-compose.workspace-e2e.yml \
     up -d --build training-api ui5-mcp
   ```

2. Run Cypress against live backends:

   ```bash
   bash scripts/operationalize/run-ui5-workspace-live-e2e.sh
   ```

See [apps/workspace/README.md](../../src/generativeUI/ui5-webcomponents-ngx-main/apps/workspace/README.md#testing) for details. CI analogue: [.github/workflows/ci-workspace-integration.yml](../../.github/workflows/ci-workspace-integration.yml).

## 6. Where to open the UIs

- **Root platform**: browser → `http://localhost` (via `api-gateway`), training Angular shell behind nginx.
- **Suite gateway**: `http://localhost:8080/` (index links to `/training/`, `/ui5/`, `/aifabric/`, `/health`).

## 7. Ongoing operations

- Monitor `/health` and `/api/v1/training/capabilities` when using the suite gateway ([gateway README](../../src/generativeUI/gateway/README.md)).
- Rotate AI Core and HANA credentials via secret store (Kyma Secret, CF credentials, or Docker secrets files).
- Regenerate SBOM artifacts if your release process requires it: [docs/sbom/README.md](../sbom/README.md).
