# Training Console

Full-platform UI for the SAP AI Training stack — covering all four `training-main` components: **Pipeline**, **Model Optimizer**, **HANA Explorer**, and **Data Explorer**.
Includes integrated **Data Cleaning** workflows for preparing model training data inside the same app.

Built with **Angular 20** + **SAP UI5 Web Components**.

---

## Architecture

```
training-webcomponents-ngx/
├── apps/
│   └── angular-shell/        # Angular 20 standalone SPA
│       ├── src/
│       │   ├── app/
│       │   │   ├── components/shell/   # ShellBar + SideNav layout
│       │   │   ├── guards/             # authGuard (optional JWT)
│       │   │   ├── interceptors/       # authInterceptor (Bearer token)
│       │   │   ├── pages/
│       │   │   │   ├── dashboard/      # System health, GPU status, graph stats
│       │   │   │   ├── pipeline/       # 7-stage Text-to-SQL pipeline
│       │   │   │   ├── model-optimizer/# Model catalog + job management
│       │   │   │   ├── hana-explorer/  # HANA Cloud explorer + SQL workspace
│       │   │   │   ├── data-explorer/  # Banking Excel/CSV asset browser
│       │   │   │   └── chat/           # LLM chat (OpenAI-compatible API)
│       │   │   └── services/           # ApiService, AuthService
│       │   ├── index.html
│       │   ├── main.ts
│       │   └── styles.scss
│       └── proxy.conf.json   # /api → localhost:8001 (dev)
└── packages/
    └── api-server/           # FastAPI CORS proxy → nvidia-modelopt :8001
```

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend framework | Angular 20 (standalone components) |
| UI components | SAP UI5 Web Components via `@ui5/webcomponents-ngx` |
| State | Angular signals + RxJS |
| Styling | SAP Fiori CSS variables + SCSS |
| Build | Nx 22 monorepo |
| Backend proxy | FastAPI + httpx (async reverse proxy) |
| Containerisation | Docker + nginx |

## Prerequisites

- Node.js ≥ 20
- Yarn 4 (via Corepack)
- Python 3.12+ (for `packages/api-server`)
- `nvidia-modelopt` backend running on port 8001

## Quick Start (Development)

### 1. Install dependencies

```bash
cd src/generativeUI/training-webcomponents-ngx
yarn install
```

### 2. Start the Angular dev server

```bash
yarn nx serve angular-shell
# → http://localhost:4200
# API calls proxied to http://localhost:8004 via proxy.conf.json
# OCR calls proxied to http://localhost:8060
```

### 3. (Optional) Start the FastAPI proxy

```bash
cd packages/api-server
pip install -r requirements.txt
cp .env.example .env
uvicorn src.main:app --reload --port 8004
```

## Production Build

```bash
yarn nx build angular-shell --configuration production
# Output: dist/apps/angular-shell/browser/
```

## Docker Compose

Operational checklist (platform vs suite gateway, secrets, smoke tests): [docs/runbooks/operationalize-apps.md](../../../docs/runbooks/operationalize-apps.md).

```bash
# From the repo root, set production secrets first:
cp .env.example .env
cp -R .secrets.example .secrets

# Then start the production-style gateway:
docker compose -f docker-compose.yml up -d
# Public app → http://localhost

# For local development through the gateway:
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d api-gateway
# Public app still → http://localhost
# Live Angular dev app → http://localhost:4200
```

For real production values:
- Edit `.env` for non-secret config like `HANA_HOST`, `AICORE_AUTH_URL`, and `AICORE_BASE_URL`.
- Replace the files in `.secrets/` with the real credentials.

## Authentication

Auth is controlled by `window.__TRAINING_CONFIG__`:

- `authMode: 'none'` with `requireAuth: false` — open access, no login required
- `authMode: 'token'` with `requireAuth: true` — redirects to `/login`, bearer token stored in `sessionStorage`
- `authMode: 'edge'` with `requireAuth: true` — ingress or edge proxy handles sign-in, and the SPA stays same-origin behind that boundary

For Kyma production, the recommended browser-facing model is `authMode: 'edge'` with an OIDC edge such as IAS or XSUAA in front of the gateway.

## Environment Variables

### Backend Proxy (`packages/api-server`)
The FastAPI proxy uses the following environment variables. They can be set in a `.env` file in the `packages/api-server` directory.

- `MODELOPT_URL` — The URL of the upstream NVIDIA ModelOpt service (default: `http://localhost:8001`).
- `ALLOWED_ORIGINS` — Comma-separated list of origins allowed by CORS (default: `http://localhost:4200,http://localhost:4201`).
- `PORT` — The port the proxy should bind to (default: `8000`).
- `MAX_BODY_BYTES` — The maximum allowed request body size in bytes (default: 10MB).
- `PROXY_RATE_LIMIT` — The slowapi rate limit for proxy requests (default: `60/minute`).

## Pages

| Route | Description |
|---|---|
| `/dashboard` | System health, GPU utilisation, graph store stats |
| `/pipeline` | 7-stage Text-to-SQL data generation pipeline |
| `/model-optimizer` | Model catalog browser + quantisation job management |
| `/hana-explorer` | HANA Cloud explorer with live SQL workspace |
| `/data-explorer` | Banking Excel/CSV training data asset browser |
| `/data-cleaning` | Native data cleaning copilot + workflow execution |
| `/chat` | OpenAI-compatible LLM chat (proxied to ModelOpt backend) |

## Backend API Endpoints (proxied via `/api`)

| Endpoint | Description |
|---|---|
| `GET /health` | Service health |
| `GET /gpu/status` | GPU metrics |
| `GET /models/catalog` | Available models |
| `GET /jobs` | List optimisation jobs |
| `POST /jobs` | Create optimisation job |
| `GET /hana/stats` | HANA Cloud connection status |
| `POST /hana/query` | Execute read-only HANA SQL |
| `POST /v1/chat/completions` | OpenAI-compatible chat |

## Quality Gates

```bash
yarn nx lint angular-shell      # ESLint
yarn nx test angular-shell      # Jest unit tests
yarn nx build angular-shell     # TypeScript compilation check
```
