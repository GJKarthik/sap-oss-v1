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

**Communication**: The frontend talks to two MCP backends (LangChain HANA on `:9140`, AI Core Streaming on `:9190`) via JSON-RPC, and to the FastAPI backend on `:8000` for auth, governance, and metrics.

## Prerequisites

- **Node.js** >= 18 and **Yarn** 4.x
- **Python** >= 3.11
- Environment variable `JWT_SECRET_KEY` set (required for the API server)

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

## Development

| Command | Description |
|---|---|
| `yarn start` | Start Angular dev server |
| `yarn build` | Production build (all projects) |
| `yarn lint` | Lint all projects |
| `yarn test` | Run all Jest tests |
| `yarn graph` | Visualize Nx dependency graph |

### Key Design Decisions

- **Lazy loading**: All page components are standalone and loaded via `loadComponent()` for optimal bundle splitting.
- **Subscription cleanup**: All components use `takeUntilDestroyed(DestroyRef)` for automatic observable cleanup.
- **Auth flow**: JWT tokens are managed by `AuthService` and automatically injected by `AuthInterceptor`.
- **MCP protocol**: `McpService` communicates with backend services via JSON-RPC 2.0 over HTTP.
- **Module boundaries**: Nx enforces `type:app` → `type:lib` dependency constraints via ESLint.

## API Documentation

When the backend is running, interactive API docs are available at:
- **Swagger UI**: http://localhost:8000/api/docs
- **ReDoc**: http://localhost:8000/api/redoc
- **Prometheus Metrics**: http://localhost:8000/metrics
