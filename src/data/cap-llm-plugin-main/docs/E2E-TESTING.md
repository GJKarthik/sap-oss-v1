# E2E Testing Guide

This document explains how to run, extend, and understand the E2E test suite for `cap-llm-plugin`.

## Overview

The E2E tests use a **real Express HTTP server** that wraps the plugin methods as REST endpoints, with all external dependencies (SAP AI Core SDK, CDS, HANA DB) replaced by deterministic mocks. This gives realistic HTTP-level test coverage without requiring live credentials.

```
HTTP request → Express route → CAPLLMPlugin method → Mocked SDK/DB → HTTP response
```

### Test files

| File | Tests | What it covers |
|------|-------|----------------|
| `tests/e2e/smoke.test.js` | 10 | Server health, all endpoints reachable, error handling basics |
| `tests/e2e/chat-flow.test.js` | 7 | Chat completion: single-turn, multi-turn, config variants, error cases |
| `tests/e2e/rag-flow.test.js` | 9 | RAG pipeline: full flow, result ordering, embedding, search, error cases |

### Infrastructure files

| File | Purpose |
|------|---------|
| `tests/e2e/server.js` | Express server — `createApp(plugin)` + `startServer(app, port)` |
| `tests/e2e/ui/index.html` | UI5 Horizon test page (chat + RAG sections) |
| `tests/e2e/helpers/setup-plugin.js` | `setupPlugin()` — creates mocked plugin instance for Jest |
| `tests/e2e/helpers/mock-ai-core.js` | SDK response factories (embedding, chat, search, filters) |

## Running locally

### Run all E2E tests

```bash
npm run test:e2e
```

### Run a single E2E test file

```bash
npx jest tests/e2e/smoke.test.js --verbose
npx jest tests/e2e/chat-flow.test.js --verbose
npx jest tests/e2e/rag-flow.test.js --verbose
```

### Run E2E in CI mode (with JUnit XML output)

```bash
npm run test:e2e:ci
# Outputs: test-results/junit.xml
```

### Start the server manually (standalone mode)

Useful for manual browser testing or debugging with curl:

```bash
node tests/e2e/server.js
# Server running at http://localhost:4004
```

Then test with curl:

```bash
# Health check
curl http://localhost:4004/api/health

# Chat completion
curl -X POST http://localhost:4004/api/chat \
  -H "Content-Type: application/json" \
  -d '{"config":{"modelName":"gpt-4o","resourceGroup":"default"},"payload":{"messages":[{"role":"user","content":"Hello"}]}}'

# Embedding
curl -X POST http://localhost:4004/api/embedding \
  -H "Content-Type: application/json" \
  -d '{"config":{"modelName":"text-embedding-ada-002","resourceGroup":"default"},"input":"test query"}'

# RAG pipeline
curl -X POST http://localhost:4004/api/rag \
  -H "Content-Type: application/json" \
  -d '{"input":"What is HANA?","tableName":"DOCS","embeddingColumnName":"EMBEDDING","contentColumn":"TEXT","chatInstruction":"Answer.","embeddingConfig":{"modelName":"text-embedding-ada-002","resourceGroup":"default"},"chatConfig":{"modelName":"gpt-4o","resourceGroup":"default"},"topK":3}'
```

Open the UI5 test page in a browser: [http://localhost:4004](http://localhost:4004)

### Run all tests (unit + integration + E2E)

```bash
npm test
```

## Timing

| Suite | Tests | Typical run time |
|-------|-------|-----------------|
| smoke | 10 | ~50 ms |
| chat-flow | 7 | ~30 ms |
| rag-flow | 9 | ~30 ms |
| **Total E2E** | **26** | **< 1 second** |

Full suite (all 17 suites, 299 tests): ~1–2 seconds.

## Configuration

### Jest config (`jest.config.js`)

The E2E project is isolated from unit/integration tests:

```js
{
  displayName: "e2e",
  testMatch: ["**/tests/e2e/**/*.test.js"],
  retryTimes: 2,        // retry flaky tests up to 2 times
  testTimeout: 15000,   // 15s per test
}
```

### Port assignment

All E2E tests use **port 0** (OS-assigned) to avoid conflicts when test files run in parallel. The actual port is read from `server.address().port` after `startServer(app, 0)` resolves.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_PORT` | `4004` | Port for standalone `node tests/e2e/server.js` |
| `JEST_JUNIT_OUTPUT_DIR` | `test-results` | JUnit XML output directory |
| `JEST_JUNIT_OUTPUT_NAME` | `junit.xml` | JUnit XML filename |

## Adding new E2E tests

1. Create `tests/e2e/<feature>-flow.test.js`
2. Use the standard pattern:

```js
const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

let BASE;

describe("E2E <Feature> Flow", () => {
  let server;

  beforeAll(async () => {
    const { plugin } = setupPlugin();
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => server.close(done));

  test("my scenario", async () => {
    const res = await fetch(BASE + "/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ /* ... */ }),
    });
    const data = await res.json();
    expect(res.status).toBe(200);
    // assert on data...
  });
});
```

3. To override a specific mock behaviour for one test suite, pass overrides to `setupPlugin()`:

```js
const { plugin } = setupPlugin({
  chatCompletion: jest.fn().mockResolvedValue(myCustomResponse),
});
```

## CI pipeline

E2E tests run in `.github/workflows/e2e.yml`:
- Triggered on every push and PR to `main`
- Matrix: Node 20 + 22
- Results published as GitHub PR annotations via `dorny/test-reporter`
- Artifacts uploaded for 14 days
