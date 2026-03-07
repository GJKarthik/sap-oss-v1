# Day 55 — OTel Trace Validation

## Overview

This document describes the complete OpenTelemetry trace topology for the
`cap-llm-plugin` stack and explains how to validate it locally using Jaeger.

---

## Trace Topology

A single user action (e.g. a RAG chat message) produces a tree of spans
across three instrumentation layers:

```
[Angular browser]
  └── rag.ask_question                    (Layer 3 — angular-tracing.ts)
        └── cap-llm-plugin.getRagResponseWithConfig   (Layer 1 — cap-llm-plugin.ts)
              ├── cap-llm-plugin.getEmbeddingWithConfig
              │     └── HTTP POST /embeddings          (Layer 2 — ai-sdk-middleware.ts)
              ├── cap-llm-plugin.similaritySearch
              └── cap-llm-plugin.getChatCompletionWithConfig
                    └── HTTP POST /chat/completions    (Layer 2 — ai-sdk-middleware.ts)
```

The W3C `traceparent` header is injected at two points:

| Injection point | Where |
|---|---|
| Angular → CAP (HTTP) | `TracingInterceptor` / `tracingInterceptorFn` clones the `HttpRequest` with propagated headers |
| CAP → AI Core (HTTP) | `createOtelMiddleware` enriches the `requestConfig.headers` before forwarding to `@sap-cloud-sdk/http-client` |

---

## Span Reference

### Layer 1 — CAP method spans

| Span name | Key attributes | Key events |
|---|---|---|
| `cap-llm-plugin.getEmbeddingWithConfig` | `llm.embedding.model`, `llm.resource_group` | `embedding_response_received` |
| `cap-llm-plugin.getChatCompletionWithConfig` | `llm.chat.model`, `llm.resource_group` | `chat_completion_response_received` |
| `cap-llm-plugin.getRagResponseWithConfig` | `llm.embedding.model`, `llm.chat.model`, `llm.resource_group` | `embedding_generated`, `similarity_search_completed`, `chat_completion_received` |
| `cap-llm-plugin.similaritySearch` | `db.hana.table`, `db.hana.algo`, `db.hana.top_k`, `db.hana.embedding_dims` | `similarity_search_completed` |
| `cap-llm-plugin.getHarmonizedChatCompletion` | `llm.chat.model`, `llm.resource_group` | `chat_completion_response_received` |
| `cap-llm-plugin.getContentFilters` | `llm.content_filter.hate`, `llm.content_filter.violence`, etc. | — |

### Layer 2 — HTTP middleware spans (`ai-sdk-middleware.ts`)

| Span name | Key attributes | Key events |
|---|---|---|
| `HTTP POST /embeddings` | `http.method`, `http.url`, `http.status_code`, `ai_core.endpoint`, `ai_core.resource_group`, `ai_core.destination` | `ai_core.request_sent`, `ai_core.response_received` |
| `HTTP POST /chat/completions` | same as above | same as above |

Status is set to `ERROR` for HTTP status ≥ 400.

### Layer 3 — Angular interaction spans (`angular-tracing.ts`)

| Span name pattern | Key attributes |
|---|---|
| `chat.<label>` | `llm.interaction = "chat"` |
| `rag.<label>` | `llm.interaction = "rag"` |
| `filter.<label>` | `llm.interaction = "filter"` |

---

## Local Jaeger Setup

### Prerequisites

- Docker + Docker Compose

### Start

```bash
docker compose -f docker/jaeger/docker-compose.yml up -d
```

This starts:
- **Jaeger all-in-one** — UI at http://localhost:16686
- **OTel Collector** — OTLP HTTP receiver on port 4319, forwards to Jaeger

### Configure your Node.js / CAP process

Install the OTel SDK packages (not in plugin's devDeps — install in your app):

```bash
npm install \
  @opentelemetry/sdk-node \
  @opentelemetry/exporter-trace-otlp-http \
  @opentelemetry/auto-instrumentations-node
```

Bootstrap before your CAP server starts (e.g. `tracing.js`):

```js
const { NodeSDK } = require("@opentelemetry/sdk-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: "http://localhost:4319/v1/traces",   // OTel Collector HTTP port
  }),
  instrumentations: [getNodeAutoInstrumentations()],
  serviceName: "cap-llm-plugin",
});

sdk.start();
process.on("SIGTERM", () => sdk.shutdown());
```

Run your CAP server with:

```bash
node -r ./tracing.js node_modules/.bin/cds run
```

### Configure the Angular app

```bash
npm install \
  @opentelemetry/api \
  @opentelemetry/sdk-trace-web \
  @opentelemetry/exporter-trace-otlp-http \
  @opentelemetry/context-zone
```

See `examples/angular-demo/app.bootstrap.ts` for the full bootstrap code.
Set the OTLP endpoint to `http://localhost:4319/v1/traces`.

---

## Verifying a Trace in Jaeger UI

1. Open http://localhost:16686
2. Select service **`cap-llm-plugin`** in the left panel
3. Click **Find Traces**
4. Open any trace — you should see:
   - The Angular `rag.*` or `chat.*` span at the top
   - `cap-llm-plugin.*` child spans below
   - `HTTP POST /embeddings` and `HTTP POST /chat/completions` as leaf spans
5. Click on an `HTTP POST` span and verify:
   - `traceparent` header was injected (visible in span tags)
   - `ai_core.endpoint` attribute is present
   - `ai_core.response_received` event is present

### Expected trace screenshot reference

```
Trace: rag.ask_question  (450ms)
  ├─ cap-llm-plugin.getRagResponseWithConfig  (420ms)
  │   ├─ cap-llm-plugin.getEmbeddingWithConfig  (80ms)
  │   │   └─ HTTP POST /embeddings  (75ms)
  │   │       tags: http.method=POST, http.status_code=200,
  │   │             ai_core.endpoint=/embeddings,
  │   │             traceparent=00-<trace-id>-<span-id>-01
  │   ├─ cap-llm-plugin.similaritySearch  (240ms)
  │   │   tags: db.hana.table=DOCS, db.hana.algo=COSINE_SIMILARITY
  │   └─ cap-llm-plugin.getChatCompletionWithConfig  (95ms)
  │       └─ HTTP POST /chat/completions  (90ms)
  │           tags: http.method=POST, http.status_code=200,
  │                 ai_core.endpoint=/chat/completions
  └─ events: embedding_generated, similarity_search_completed,
             chat_completion_received
```

---

## Automated Validation (no Jaeger needed)

The span tree is validated programmatically in:

```
tests/unit/otel-trace-topology.test.js   (45 tests)
```

Run:

```bash
npx jest tests/unit/otel-trace-topology.test.js --verbose
```

Test suites:
- **Layer 1 — CAP method spans** — span names, attributes, events, OK/ERROR status, `span.end()` lifecycle
- **Layer 2 — HTTP middleware spans** — endpoint-based names, all semantic attributes, event names, `traceparent` injection, status code mapping
- **Layer 3 — Angular interaction spans** — `llm.interaction` attribute, namespaced span names, error propagation
- **Full trace topology** — all three layers produce spans in a single simulated RAG request; every span in the tree calls `span.end()` exactly once
- **Trace correlation** — `traceparent` is present in injected HTTP headers and Angular request clones

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No spans in Jaeger | OTel SDK not initialised before first request | Ensure `sdk.start()` is called before CDS `require` |
| Spans appear but no `traceparent` in AI Core calls | `createOtelMiddleware` not passed to `embed()` / `chatCompletion()` | Check `middleware` option is wired in `cap-llm-plugin.ts` |
| Angular spans not linked to CAP spans | `ZoneContextManager` not registered | Add `provider.register({ contextManager: new ZoneContextManager() })` |
| OTel Collector not receiving spans | Port mismatch | Angular app → port 4319 (Collector), CAP app → port 4319 (Collector), direct Jaeger → port 4318 |
| `@opentelemetry/api` not found warning | Package not installed | `npm install @opentelemetry/api` in the consuming app (it is an optional peer dep) |
