# Technical Assessment: world-monitor-main

**Repository path:** `src/generativeUI/world-monitor-main`
**Assessment date:** 9 March 2026
**Assessed by:** Cascade (AI Code Assistant)

---

## 1. Overview

`world-monitor-main` is a real-time global intelligence dashboard published as **World Monitor** (v2.5.4, AGPL-3.0). Its primary purpose is to aggregate, correlate, and AI-synthesise open-source intelligence from over 100 external data feeds — covering geopolitical events, military activity, infrastructure health, financial markets, and climate anomalies — and render them on a WebGL 3D globe with 35+ toggleable data layers.

Within this SAP OSS repository the project serves an additional, more specific function: it acts as an **AI governance observability monitor**. It provides a live audit panel for AI decision records (allowed/blocked/anonymised), a regulation panel tracking AI regulatory deadlines and country profiles, an MCP server that exposes monitoring tools to the broader SAP MCP mesh, and a Python agent (`WorldMonitorAgent`) that enforces content-based LLM routing rules derived from Mangle governance facts. HANA metadata integration is declared through the `hana-toolkit-mcp` service registration and the `regulations/mangle/rules.mg` import in the agent domain rules.

The front-end is built in **pure TypeScript** (no framework — custom DOM helpers throughout), bundled with **Vite 6**, and rendered with **MapLibre GL JS** and **deck.gl**. Three product variants share a single codebase: World Monitor (geopolitics), Tech Monitor (AI/tech industry), and Finance Monitor (markets and central banks), switched at build time via the `VITE_VARIANT` environment variable.

---

## 2. Repository Layout

The repository root holds `index.html` (the SPA entry point), `settings.html` (a separate settings page), `package.json`, `vite.config.ts`, `playwright.config.ts`, `tsconfig.json`, `Makefile`, `middleware.ts` (Vercel edge middleware), and `vercel.json` (deployment routing). The `src/` tree (~251 items) contains the entire front-end: `App.ts` (188 KB, the main application shell), `main.ts` (SPA bootstrap), `settings-main.ts` (settings page bootstrap), `components/` (53 UI panel files), `services/` (79 data-fetching and analysis service files), `config/` (28 static configuration modules), `generated/` (35 proto-generated client/server stubs), `workers/` (ML and analysis Web Workers), `locales/` (14 language bundles), `styles/`, `types/`, and `utils/`.

The `server/` tree provides the Deno/Node sidecar (sebuf-generated handlers): `router.ts` maps `POST /api/*` paths to generated handlers, `cors.ts` and `error-mapper.ts` are shared middleware, and `worldmonitor/` hosts 18 domain subdirectories (audit, aviation, climate, conflict, cyber, displacement, economic, infrastructure, intelligence, maritime, market, military, news, prediction, research, seismology, unrest, wildfire) each containing generated TypeScript route handlers. `api/` holds Vercel serverless functions: `rss-proxy.js` (RSS aggregation), `og-story.js` (Open Graph story generation), `story.js`, `download.js`, `register-interest.js`, `fwdstart.js`, `version.js`, plus subdirectories for `eia/`, `youtube/`, and `[domain]/` dynamic routes.

`proto/` (~96 files) defines the protobuf service contracts from which `src/generated/` is auto-generated using the `sebuf` tool. `mangle/` holds governance rules in `domain/agents.mg`, `domain/data_products.mg`, and `a2a/mcp.mg`. `agent/world_monitor_agent.py` is the Python governance agent. `mcp_server/server.py` is the MCP observability server. `convex/` holds the Convex serverless backend for email registration. `kuzu/` is a large vendored KùzuDB graph database directory. `src-tauri/` holds the Tauri desktop app configuration and a local API sidecar. `e2e/` and `tests/` cover Playwright end-to-end and Node unit tests.

---

## 3. Primary Purpose in SAP Context

Within the SAP OSS portfolio the project provides three distinct capabilities. The first is an external news and event monitor that ingests RSS feeds, ACLED conflict data, GDELT geo-events, UCDP conflict statuses, UNHCR displacement data, USGS earthquake feeds, NASA EONET events, GDACS disaster alerts, AIS vessel positions, ADS-B military flight tracks, NASA FIRMS fire detections, and cyber threat IOC feeds, then correlates them geospatially using Haversine deduplication and a convergence-scoring algorithm. The second is an AI governance observability surface: the `AuditPanel` component polls `fetchAiDecisions` and `fetchAuditSummary` every 30 seconds to display a live log of AI decisions classified as allowed, blocked, or anonymised, with classification-level badges (`confidential`, `internal`, `public`). The `RegulationPanel` tracks AI regulatory actions, upcoming compliance deadlines, and per-country regulatory profiles across multiple governance frameworks. The third is an MCP mesh monitor: the Python MCP server (`mcp_server/server.py`) runs on port 9170 and registers itself alongside 12 other SAP MCP services (ports 9090–9881) in a shared service registry, exposing tools for `get_metrics`, `record_metric`, `health_check`, `list_services`, `refresh_services`, `get_alerts`, `create_alert`, `get_logs`, and `mangle_query`.

---

## 4. Core Architecture

The application runs across four execution environments. In the browser, `App.ts` orchestrates component lifecycle, map rendering (MapLibre GL JS + deck.gl), panel management, and service calls. Long-running analysis work — news clustering, correlation signal detection, ML inference — is offloaded to Web Workers (`analysis-worker.ts`, `ml-worker.ts`). On the server side, Vercel serverless functions in `api/` proxy authenticated external APIs (Groq, Finnhub, EIA, ACLED, Cloudflare, NASA FIRMS, AISStream) so that API keys never reach the browser. The sebuf-generated sidecar in `server/` provides strongly-typed RPC endpoints consumed via generated TypeScript clients (`src/generated/client/`). For the desktop variant, Tauri wraps the same web app in a native shell with a local API sidecar (`src-tauri/sidecar/`) that proxies cloud fallback API calls, stores secrets in the OS keychain, and serves them through an HTTP interface at `127.0.0.1:46123`.

The inference pipeline follows a 4-tier provider fallback chain. Ollama (local, no data egress) is tried first with a 5-second timeout, then Groq (cloud, 14,400 req/day free), then OpenRouter (cloud, 50 req/day free), and finally a browser-side T5 model via Transformers.js (`@xenova/transformers`) as a last resort. Summarisation results are Redis-cached server-side (Upstash, 24-hour TTL) and content-deduplicated so that concurrent users sharing the same headlines trigger exactly one LLM call. All AI calls are routed through the `summarization.ts` service which wraps the `NewsServiceClient.summarizeArticle()` RPC and uses a circuit breaker to prevent cascade failures.

---

## 5. Front-End (`src/`)

`App.ts` (188 KB) is the monolithic application shell. It bootstraps all services, instantiates the map and all panels, manages the active variant configuration (`VITE_VARIANT`), handles deep-link URL state (map centre, zoom, active layers, time range), and drives the full render cycle. `main.ts` and `settings-main.ts` are the Vite entry points for the SPA and the settings page respectively.

The 53 components in `src/components/` are all plain TypeScript classes extending a shared `Panel` base. Notable panels relevant to the SAP governance use case include `AuditPanel.ts` (AI decision log with 30-second polling), `RegulationPanel.ts` (AI regulatory timeline, deadlines, framework matrix, country profiles), `InsightsPanel.ts` (AI-generated world brief with attribution), `StrategicRiskPanel.ts` (composite risk score with trend detection), `StrategicPosturePanel.ts` (cached theater posture), `CIIPanel.ts` (Country Instability Index scores for 22 nations), `ServiceStatusPanel.ts` (health of all registered services), and `RuntimeConfigPanel.ts` (live feature toggles and secret management). The map component is split between `Map.ts` (126 KB, MapLibre GL JS integration) and `DeckGLMap.ts` (155 KB, deck.gl layer management) with `MapContainer.ts` coordinating them, and `MapPopup.ts` (114 KB, rich popup rendering for all layer types).

The 79 services in `src/services/` handle all data acquisition, analysis, and state management. Core analysis services include `analysis-core.ts` (pure functions for news clustering via Jaccard similarity, topic velocity, and correlation detection), `signal-aggregator.ts` (collects internet outages, military flights, vessel positions, protests, AIS disruptions, and satellite fire detections into `GeoSignal` records clustered by country with convergence scoring), `cross-module-integration.ts` (unifies convergence alerts, CII spike alerts, and infrastructure cascade alerts into a single `UnifiedAlert` stream with Haversine-based deduplication within a 200 km / 2-hour window), `country-instability.ts` (derives `CountryScore` for 22 Tier-1 nations from four weighted sub-scores: unrest, conflict, security, and information), `focal-point-detector.ts` (correlates entities across all signal types to identify convergence hotspots), and `threat-classifier.ts` (three-tier classification: keyword → on-device ML → async LLM override, producing `ThreatClassification` with `level`, `category`, `confidence`, and `source` fields). The `summarization.ts` service implements the 4-tier LLM fallback chain. `runtime-config.ts` manages 15 named `RuntimeFeatureId` toggles and 25 named `RuntimeSecretKey` values, sourced from environment variables (Vercel deployment) or the Tauri sidecar vault (desktop deployment).

---

## 6. Proto-First API Contracts

All server-to-client data contracts are defined in `proto/` using Protocol Buffers. The `sebuf` code-generation tool produces matching TypeScript server handlers (in `server/worldmonitor/`) and client stubs (in `src/generated/client/`) from these definitions. The `server/router.ts` is a minimal `Map`-based dispatcher that matches `METHOD /path` keys to generated handler functions — no regex, no dynamic segments, consistent with sebuf's static POST routes convention.

The generated client layer is used throughout `src/services/` — for example, `summarization.ts` calls `NewsServiceClient.summarizeArticle()` rather than constructing raw `fetch` calls to provider-specific endpoints. This protobuf-first approach gives typed request/response schemas, generated OpenAPI documentation, and consistent error handling across all 17 typed services.

---

## 7. Mangle Governance Layer

The `mangle/` directory contains three files that encode AI governance rules for the agent. `mangle/domain/data_products.mg` defines the `world-monitor-service-v1` data product under the ODPS 4.1 schema. It declares three output ports: `news-summary` (public, AI Core routing permitted), `trend-analysis` (internal, vLLM only), and `impact-assessment` (confidential, vLLM only). It also declares two input ports, a prompting policy (max 4096 tokens, temperature 0.4, structured response format), regulatory framework membership (`MGF-Agentic-AI` and `AI-Agent-Index`), autonomy level L2 with mandatory human oversight, four safety controls (guardrails, monitoring, audit-logging, content-filtering), and quality SLAs (99.5% availability, 3000 ms P95 latency, 150 req/min throughput).

`mangle/domain/agents.mg` configures the `world-monitor-agent` at autonomy level L2. It enumerates five permitted tools (`summarize_news`, `analyze_trends`, `search_events`, `get_headlines`, `mangle_query`) and three approval-gated actions (`impact_assessment`, `competitor_analysis`, `export_report`). Content-based routing rules classify requests as public news (routed to AI Core) or internal analysis (routed to vLLM) based on keyword matching. High-risk actions additionally trigger the `requires_human_review` predicate. Every tool invocation (permitted or approval-gated) is covered by the `requires_audit` rule at full audit level. The file imports from `../regulations/mangle/rules.mg`, which resides in a sibling `regulations/` project, providing cross-repository governance dimension facts.

`mangle/a2a/mcp.mg` registers nine MCP services in the shared A2A service registry (world-monitor on 9170, ai-sdk-mcp on 9090, cap-llm-mcp on 9100, data-cleaning on 9110, elasticsearch on 9120, hana-toolkit on 9130, langchain on 9140, odata-vocab on 9150, ui5-ngx on 9160). It routes the `/metrics`, `/alerts`, and `/health` intents to the world-monitor service, maps eight tools to it, and defines `alert_critical`/`alert_warning` severity derivation rules and `service_healthy`/`service_unhealthy` health predicates.

---

## 8. Python Governance Agent (`agent/world_monitor_agent.py`)

`WorldMonitorAgent` is a Python class that wraps a `MangleEngine` (a Python dict-backed simulation of the Mangle rule evaluator) and exposes an `async invoke(prompt, context)` method. On each invocation it evaluates `route_to_aicore` and `route_to_vllm` predicates against the prompt text, checks `requires_human_review` for the requested tool, verifies `safety_check_passed`, retrieves the prompting policy, and dispatches the call to the appropriate MCP endpoint (`http://localhost:9160/mcp` for AI Core-routed requests, `http://localhost:9180/mcp` for vLLM-routed requests). Every invocation is recorded in an in-process audit log with timestamp, agent identifier, status, tool name, backend, prompt hash, and prompt length. The `check_governance` method returns a full governance decision record without executing the tool, suitable for pre-flight checks.

The default routing is conservative: when neither AI Core nor vLLM routing is positively matched, the agent falls back to vLLM rather than AI Core. The `MangleEngine._load_rules()` method seeds the Python fact dictionary from the same keyword sets and approval lists as the Mangle `.mg` files, keeping the Python implementation in sync with the declarative rules.

---

## 9. MCP Observability Server (`mcp_server/server.py`)

The MCP server is a pure-stdlib Python HTTP server (no FastAPI or external dependencies) that implements the JSON-RPC 2.0 MCP protocol. It listens on port 9170 and registers eight tools: `get_metrics`, `record_metric`, `health_check`, `list_services`, `refresh_services`, `get_alerts`, `create_alert`, `get_logs`, and `mangle_query`. It exposes four MCP resources: `monitor://metrics`, `monitor://alerts`, `monitor://services`, and `mangle://facts`.

At startup it initialises a service registry in `self.facts["service_registry"]` with 13 entries covering the full SAP MCP mesh (ports 9090–9881 plus the gRPC Mangle query service on `grpc://localhost:50051`). Metrics are stored in-process in `self.metrics` as a simple dict keyed by metric name. Alerts are stored in `self.facts["alerts"]`. The `health_check` tool validates the target URL scheme before issuing an HTTP GET, clamps the timeout to a configurable maximum (`MCP_MAX_HEALTH_TIMEOUT`, default 30 seconds), and `refresh_services` batches health checks across registered services up to `MCP_MAX_REFRESH_SERVICES` (default 25). The `mangle_query` tool accepts a predicate name and JSON-encoded argument array and is intended to be wired to the Mangle query service, though the current implementation returns the raw fact store rather than executing a Mangle derivation.

Input limits are enforced via `MAX_REQUEST_BYTES` (default 1 MB), `MAX_LOG_LIMIT` (default 500 entries), and `MAX_REFRESH_SERVICES`. CORS is enforced via an `CORS_ALLOWED_ORIGINS` environment variable (default `http://localhost:3000`).

---

## 10. Build System and Variants

Vite 6 is the bundler. `vite.config.ts` defines a `VARIANT_META` map for the three product variants (`full`, `tech`, `finance`) and injects variant-specific title, description, keywords, Open Graph tags, and PWA manifest into the build. A custom `brotliPrecompressPlugin` generates `.br` pre-compressed versions of all JS, CSS, HTML, SVG, JSON, WASM, and XML assets at build time, bypassing runtime Brotli encoding. TypeScript is compiled via `tsc` before Vite builds.

The Tauri desktop build path (`build:desktop`) runs `build-sidecar-sebuf.mjs` first to compile the local API sidecar, then `tsc`, then `vite build`. Desktop packages for macOS (ARM64 and Intel), Windows, and Linux (AppImage) are produced by `scripts/desktop-package.mjs` and can be optionally code-signed. Version synchronisation between `package.json` and the Tauri manifest is enforced by `scripts/sync-desktop-version.mjs`, which is run as a pre-step for all desktop builds.

The PWA configuration (via `vite-plugin-pwa`) registers a service worker that caches the map tile layer and static assets for offline use. The `VITE_MAP_INTERACTION_MODE` variable switches between `3d` (pitch/rotation enabled) and `flat` (2D only) map interaction modes.

---

## 11. Data Sources and External API Dependencies

The service ingests data from a large number of external sources across several categories. For conflict and geopolitical data it uses UCDP (Uppsala Conflict Data Program, public API), ACLED (requires `ACLED_ACCESS_TOKEN`), and GDELT geo-events (public). For natural disasters it uses USGS earthquake feed (M4.5+, public), GDACS disaster alerts (public), and NASA EONET (public). For displacement it uses UNHCR (public, CC BY 4.0). For military and vessel tracking it uses AISStream (requires `AISSTREAM_API_KEY`) for live AIS vessel positions and OpenSky Network (requires `OPENSKY_CLIENT_ID`/`OPENSKY_CLIENT_SECRET`) for ADS-B aircraft. For cyber threats it uses URLhaus/AbuseChThreat, AlienVault OTX (requires `OTX_API_KEY`), and AbuseIPDB (requires `ABUSEIPDB_API_KEY`). For infrastructure it uses Cloudflare Radar (requires `CLOUDFLARE_API_TOKEN`) for internet outage data. For fire detection it uses NASA FIRMS (requires `NASA_FIRMS_API_KEY`). For markets it uses Finnhub (requires `FINNHUB_API_KEY`). For economic data it uses FRED Federal Reserve (requires `FRED_API_KEY`) and EIA (requires `EIA_API_KEY`). For AI summarisation it uses Groq (requires `GROQ_API_KEY`) and OpenRouter (requires `OPENROUTER_API_KEY`) with Ollama as a local-first option. Aircraft enrichment uses Wingbits (requires `WINGBITS_API_KEY`). RSS aggregation is handled server-side by `api/rss-proxy.js` to avoid CORS restrictions.

All API keys are injected as environment variables for Vercel deployments. On the desktop, they are stored in the OS keychain via the Tauri sidecar and retrieved through a local HTTP interface at `127.0.0.1:46123`. No API key is ever bundled into the client-side JavaScript bundle; all authenticated calls are proxied through Vercel serverless functions or the local sidecar.

---

## 12. Localisation

The UI supports 14 languages: English, French, Spanish, German, Italian, Polish, Portuguese, Dutch, Swedish, Russian, Arabic, Chinese, Japanese, and Turkish. Language bundles in `src/locales/` are lazy-loaded on demand — only the active language bundle is fetched, keeping the initial JavaScript payload minimal. RTL layout is supported for Arabic. The `LanguageSelector` component persists the user's selection. Region-specific RSS feeds are activated based on language preference (e.g., French selects Le Monde, Jeune Afrique, France24). AI-generated summaries are requested in the active language via the `lang` parameter on `summarizeArticle`.

---

## 13. Testing

End-to-end tests use Playwright and are organised by variant: `test:e2e:full`, `test:e2e:tech`, and `test:e2e:finance`. Visual regression tests compare screenshots per map layer and zoom level against golden snapshots. `test:e2e:runtime` specifically exercises the runtime feature-fetch paths. Unit tests in `tests/` use Node's built-in test runner (`node --test`). Sidecar-specific tests (`test:sidecar`) cover the local API server, CORS handling, YouTube embed, cyber threat, and USNI fleet endpoints individually. Playwright configuration is in `playwright.config.ts`.

---

## 14. Deployment

The web app is deployed on Vercel. `vercel.json` defines routing rules that map `/api/*` paths to serverless functions and all other paths to the SPA entry point. `middleware.ts` is a Vercel Edge Middleware that runs before all requests. The Convex serverless backend (`convex/registerInterest.ts`) stores email registrations separately from the main Vercel deployment. The AIS relay server (`scripts/ais-relay.cjs`) is designed to run on Railway as a persistent WebSocket relay for AIS vessel and OpenSky aircraft streams, bridging them to the browser via `WS_RELAY_URL` (server-side) and `VITE_WS_RELAY_URL` (client-side WebSocket).

Desktop builds are distributed as native binaries (`.exe` for Windows, `.dmg` for macOS ARM64 and Intel, `.AppImage` for Linux) packaged by `scripts/desktop-package.mjs`. The `deploy/` directory contains additional deployment configuration.

---

## 15. Evaluation of Software (9 March, 2026)

The following items require resolution before this project can be considered production-ready within the SAP AI governance context.

(1) **`mangle_query` MCP tool is not wired to a real Mangle engine.** The `mangle_query` tool in `mcp_server/server.py` accepts a predicate name and argument array but returns the raw `self.facts` dict rather than executing a Mangle derivation. The `MangleEngine` class in `agent/world_monitor_agent.py` similarly simulates rule evaluation with hardcoded Python dicts rather than invoking the actual Mangle reasoning engine. Both are labelled as integration points for the Mangle query service (`grpc://localhost:50051` in the service registry) but that wiring is not implemented. Until these are connected to a real Mangle engine, governance decisions made at runtime do not reflect rule changes in the `.mg` files without a code redeploy.

(2) **Audit log is in-process and non-persistent.** The `WorldMonitorAgent.audit_log` is a plain Python list appended to in memory. It is lost on process restart, is not exposed to the MCP `get_logs` tool, and is not written to any durable store. For the AI governance use case, audit records of LLM routing decisions (which requests were sent to AI Core vs. vLLM and which were blocked for human review) must be durable, queryable, and tamper-evident. The audit log should be written to a persistent backend — at minimum a structured log sink, ideally the same HANA-backed audit store that the `AuditPanel` reads from via `fetchAiDecisions`.

(3) **HANA integration is declared but not implemented.** `mangle/a2a/mcp.mg` registers `hana-toolkit` at `http://localhost:9130/mcp` as a peer service and `agents.mg` imports `../regulations/mangle/rules.mg` which is expected to carry HANA-backed governance dimension facts. Neither the MCP server nor the agent code contains any HANA connection, query, or schema reference. The `regulations/mangle/rules.mg` path is referenced by an `include` directive but the file does not exist in this repository — it is presumed to live in a separate `regulations/` sibling project that is not present in this workspace. This means the `governance_dimension` predicate used by `requires_human_review` in `agents.mg` is always unresolved, silently making that branch of the rule unreachable.

(4) **`CORS_ALLOWED_ORIGINS` defaults to localhost only.** The MCP server's CORS policy defaults to `http://localhost:3000,http://127.0.0.1:3000`. In any deployment where the World Monitor front-end or the AI SDK MCP client runs on a non-localhost origin (Vercel preview, SAP BTP, Docker Compose on a named host), requests to the MCP server will be rejected by CORS preflight. The allowed origins must be configurable per deployment environment and should be validated at startup rather than silently falling back to the first entry.

(5) **Metrics are in-process and non-persistent.** `MCPServer.metrics` is a plain Python dict. All recorded metrics are lost on restart and are not replicated to any time-series store. For meaningful AI governance observability — tracking LLM call volumes, latency distributions, blocked-request rates, and routing decisions over time — metrics must be written to a durable store (Prometheus remote write, Upstash Redis time-series, or equivalent). The current implementation is sufficient for smoke-testing the MCP tooling but not for production monitoring.

(6) **API keys for external threat intelligence are exposed via `RuntimeSecretKey` without rotation policy.** `runtime-config.ts` declares 25 named secret keys covering ACLED, AbuseIPDB, AlienVault OTX, URLhaus, AISStream, OpenSky, Finnhub, EIA, FRED, Wingbits, NASA FIRMS, Groq, and OpenRouter credentials. On Vercel these are injected as environment variables with no documented rotation cadence. On the desktop they are stored in the OS keychain via Tauri. Neither path has an automated rotation mechanism or secret-expiry check. Several of these sources (AbuseIPDB, OTX, AISStream) provide real-time threat intelligence that, if obtained via leaked keys, could be used by an attacker to understand exactly which threat IOCs the dashboard is tracking and which are absent from its view.
