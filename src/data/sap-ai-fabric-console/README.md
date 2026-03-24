# SAP AI Fabric Console

Enterprise-grade console for managing AI workloads on SAP AI Core, featuring real-time model deployment management, RAG-based knowledge retrieval, streaming sessions, data lineage tracking, and governance rule enforcement.

## Architecture

```
sap-ai-fabric-console/
├── apps/
│   └── angular-shell/          # Angular 20 + SAP UI5 Web Components frontend
│       └── src/
│           ├── app/
│           │   ├── components/  # Shared layout (ShellComponent)
│           │   ├── guards/      # AuthGuard (JWT-based route protection)
│           │   ├── interceptors/# AuthInterceptor (Bearer token injection)
│           │   ├── pages/       # Lazy-loaded standalone page components
│           │   └── services/    # McpService (MCP protocol), AuthService (JWT)
│           └── environments/    # Dev/prod environment configs
├── packages/
│   └── api-server/             # Python FastAPI backend
│       └── src/
│           ├── config.py       # Pydantic settings (env-based)
│           ├── main.py         # FastAPI app, CORS, Prometheus
│           └── routes/         # 8 route modules (auth, models, rag, ...)
└── nx.json                     # Nx workspace configuration
```

**Frontend**: Angular 20 with SAP UI5 Web Components (`@ui5/webcomponents-ngx`), Nx build system, Jest tests.

**Backend**: FastAPI with Pydantic models, JWT authentication (`python-jose`), structured logging (`structlog`), Prometheus instrumentation.

**Communication**: The frontend talks to the FastAPI backend on `:8000` for auth, governance, metrics, and MCP proxying. The backend forwards JSON-RPC calls to the LangChain HANA and AI Core Streaming MCP services.

**Persistence**: The backend supports `STORE_BACKEND=sqlite` for local/test use and `STORE_BACKEND=hana` for shared SAP HANA Cloud persistence. SQLite remains the default for local development.

## Quality Gates

- `yarn test --skip-nx-cache` runs the Angular and backend unit/integration suites.
- `yarn build --skip-nx-cache` produces the production Angular build.
- `yarn e2e:smoke` starts the backend and frontend locally on isolated free ports, drives a real Chrome session headlessly, verifies login plus the main routes, and fails on runtime exceptions, failed XHR/fetch/document requests, or browser `console.error` output. The default browser login mode uses the Angular login component directly for stable UI5 automation; set `E2E_LOGIN_MODE=ui` for raw keystroke coverage or `E2E_LOGIN_MODE=api` to inject a session after a real backend login.

## Prerequisites

- **Node.js** >= 18 and **Yarn** 4.x
- **Python** >= 3.11
- Environment variable `JWT_SECRET_KEY` set to a non-default value outside development and test environments

## Quick Start

### Frontend

```bash
# Install dependencies
yarn install

# Start dev server (default: http://localhost:4200)
yarn start
```

### Backend

```bash
cd packages/api-server

# Create virtual environment
python3 -m venv .venv && source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Set required env var
export JWT_SECRET_KEY="your-secret-key-here"

# Run the API server (default: http://localhost:8000)
uvicorn src.main:app --reload
```

### HANA Persistence

Use the following environment variables to move shared application state into SAP HANA Cloud:

```bash
export STORE_BACKEND=hana
export HANA_HOST="<instance>.hanacloud.ondemand.com"
export HANA_USER="<user>"
export HANA_PASSWORD="<password>"
export HANA_STORE_SCHEMA="<optional-schema>"
export HANA_STORE_TABLE_PREFIX="SAP_AIFABRIC"
```

If `STORE_BACKEND=hana`, the API keeps users, deployments, governance rules, datasources, vector-store registry state, token revocations, and rate-limit buckets in HANA instead of the local SQLite file.

## Development

| Command | Description |
|---|---|
| `yarn start` | Start Angular dev server |
| `yarn build` | Production build (all projects) |
| `yarn lint` | Lint all projects |
| `yarn test` | Run Angular Jest tests and backend pytest suites |
| `yarn graph` | Visualize Nx dependency graph |

### Key Design Decisions

- **Lazy loading**: All page components are standalone and loaded via `loadComponent()` for optimal bundle splitting.
- **Subscription cleanup**: All components use `takeUntilDestroyed(DestroyRef)` for automatic observable cleanup.
- **Auth flow**: JWT tokens are managed by `AuthService` and automatically injected by `AuthInterceptor`.
- **MCP protocol**: `McpService` communicates with the FastAPI MCP proxy via JSON-RPC 2.0 over HTTP.
- **Module boundaries**: Nx enforces `type:app` → `type:lib` dependency constraints via ESLint.
- **Nx execution**: Workspace scripts run Nx with the daemon, plugin isolation, and native command runner disabled by default so commands remain reliable in restricted or socket-limited environments.

## API Documentation

Interactive docs are enabled by default in `development` and `test` and disabled by default in production. You can override that with `EXPOSE_API_DOCS=true|false`.

When the backend is running, interactive API docs are available at:
- **Swagger UI**: http://localhost:8000/api/docs
- **ReDoc**: http://localhost:8000/api/redoc
- **Prometheus Metrics**: http://localhost:8000/metrics
