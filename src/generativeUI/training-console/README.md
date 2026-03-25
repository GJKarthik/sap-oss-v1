# Training Console

Full-platform UI for the SAP AI Training stack — covering all four `training-main` components: **Pipeline**, **Model Optimizer**, **HippoCPP**, and **Data Explorer**.

Built with **Angular 20** + **SAP UI5 Web Components**, mirroring the architecture of `sap-ai-fabric-console`.

---

## Architecture

```
training-console/
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
│       │   │   │   ├── hippocpp/       # Graph DB engine + Cypher sandbox
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
| Build | Nx 20 monorepo |
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
cd src/generativeUI/training-console
yarn install
```

### 2. Start the Angular dev server

```bash
yarn nx serve angular-shell
# → http://localhost:4200
# API calls proxied to http://localhost:8001 via proxy.conf.json
```

### 3. (Optional) Start the FastAPI proxy

```bash
cd packages/api-server
pip install -r requirements.txt
cp .env.example .env
uvicorn src.main:app --reload --port 8000
```

## Production Build

```bash
yarn nx build angular-shell --configuration production
# Output: dist/apps/angular-shell/browser/
```

## Docker Compose

```bash
# Requires training-console-modelopt:latest image
docker compose up
# Frontend → http://localhost:8080
# API proxy → http://localhost:8000
# ModelOpt → http://localhost:8001
```

## Authentication

Auth is **optional**. Controlled by `window.__TRAINING_CONFIG__.requireAuth`:

- `false` (default) — no login required
- `true` — redirects to `/login`, token stored in `sessionStorage`

API key can be set at any time via the sidebar input in the shell layout.

## Pages

| Route | Description |
|---|---|
| `/dashboard` | System health, GPU utilisation, graph store stats |
| `/pipeline` | 7-stage Text-to-SQL data generation pipeline |
| `/model-optimizer` | Model catalog browser + quantisation job management |
| `/hippocpp` | HippoCPP graph engine stats + Cypher query sandbox |
| `/data-explorer` | Banking Excel/CSV training data asset browser |
| `/chat` | OpenAI-compatible LLM chat (proxied to ModelOpt backend) |

## Backend API Endpoints (proxied via `/api`)

| Endpoint | Description |
|---|---|
| `GET /health` | Service health |
| `GET /gpu/status` | GPU metrics |
| `GET /models/catalog` | Available models |
| `GET /jobs` | List optimisation jobs |
| `POST /jobs` | Create optimisation job |
| `GET /graph/stats` | HippoCPP graph statistics |
| `POST /graph/query` | Execute Cypher query |
| `POST /v1/chat/completions` | OpenAI-compatible chat |

## Quality Gates

```bash
yarn nx lint angular-shell      # ESLint
yarn nx test angular-shell      # Jest unit tests
yarn nx build angular-shell     # TypeScript compilation check
```
