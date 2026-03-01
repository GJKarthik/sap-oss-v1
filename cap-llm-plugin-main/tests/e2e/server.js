// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * E2E Test Server
 *
 * Minimal Express server that:
 * 1. Wraps a CAPLLMPlugin instance as REST POST endpoints
 * 2. Serves a static UI5 test page
 *
 * Two modes:
 *   - Standalone: `node tests/e2e/server.js` (uses require.cache mocks)
 *   - Jest:       `createApp(plugin)` → `startServer(app)` (uses Jest mocks)
 *
 * Port 4004 by default (E2E_PORT env to override).
 */

const path = require("path");
const { toErrorResponse } = require("../../src/errors/LLMErrorResponse");
const PORT = process.env.E2E_PORT || 4004;

/**
 * Create an Express app wrapping the given plugin instance.
 * @param {object} plugin - CAPLLMPlugin instance
 * @returns {import("express").Express}
 */
function createApp(plugin) {
  const express = require("express");
  const app = express();
  app.use(express.json());
  app.use(express.static(path.join(__dirname, "ui")));

  app.post("/api/embedding", async (req, res) => {
    try {
      const { config, input } = req.body;
      const result = await plugin.getEmbeddingWithConfig(config, input);
      res.json({ embeddings: result.getEmbeddings() });
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/chat", async (req, res) => {
    try {
      const { config, payload } = req.body;
      const result = await plugin.getChatCompletionWithConfig(config, payload);
      res.json({ result: result.data || result });
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/rag", async (req, res) => {
    try {
      const {
        input, tableName, embeddingColumnName, contentColumn,
        chatInstruction, embeddingConfig, chatConfig, context, topK, algoName,
      } = req.body;
      const result = await plugin.getRagResponseWithConfig(
        input, tableName, embeddingColumnName, contentColumn,
        chatInstruction, embeddingConfig, chatConfig, context, topK, algoName,
      );
      res.json(result);
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/search", async (req, res) => {
    try {
      const { tableName, embeddingColumnName, contentColumn, embedding, algoName, topK } = req.body;
      const result = await plugin.similaritySearch(
        tableName, embeddingColumnName, contentColumn, embedding, algoName, topK,
      );
      res.json({ results: result });
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/harmonized", async (req, res) => {
    try {
      const result = await plugin.getHarmonizedChatCompletion(req.body);
      res.json({ result });
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/filters", async (req, res) => {
    try {
      const result = await plugin.getContentFilters(req.body);
      res.json({ result });
    } catch (err) {
      const { httpStatus, body } = toErrorResponse(err);
      res.status(httpStatus).json(body);
    }
  });

  app.post("/api/stream", async (req, res) => {
    const { clientConfig, chatCompletionConfig, abortOnFilterViolation } = req.body;
    // The plugin expects clientConfig / chatCompletionConfig as JSON strings
    // (it calls JSON.parse internally, matching the CDS action wire format).
    const cdsReq = { http: { res } };
    try {
      await plugin.streamChatCompletion(
        {
          clientConfig: JSON.stringify(clientConfig),
          chatCompletionConfig: JSON.stringify(chatCompletionConfig),
          abortOnFilterViolation,
        },
        cdsReq,
      );
    } catch (err) {
      // streamChatCompletion writes its own error frame and calls res.end()
      // in SSE mode, so this catch is only hit if headers were never sent
      if (!res.headersSent) {
        const { httpStatus, body } = toErrorResponse(err);
        res.status(httpStatus).json(body);
      }
    }
  });

  app.get("/api/health", (_req, res) => {
    res.json({ status: "ok", endpoints: ["/api/chat", "/api/rag", "/api/embedding", "/api/search", "/api/harmonized", "/api/filters", "/api/stream"] });
  });

  return app;
}

/**
 * Start an Express app on the given port (default from E2E_PORT or 4004).
 * Pass port=0 to let the OS assign a free port.
 * @param {import("express").Express} app
 * @param {number} [port]
 * @returns {Promise<import("http").Server>}
 */
function startServer(app, port) {
  port = port !== undefined ? port : PORT;
  return new Promise((resolve) => {
    const server = app.listen(port, () => {
      const addr = server.address();
      console.log("E2E test server running at http://localhost:" + addr.port);
      resolve(server);
    });
  });
}

// ── Standalone mode: `node tests/e2e/server.js` ─────────────────────
if (require.main === module) {
  // Use require.cache to mock dependencies without Jest
  const cdsPath = require.resolve("@sap/cds");
  const sdkPath = require.resolve("@sap-ai-sdk/orchestration");
  const anonPath = require.resolve("../../lib/anonymization-helper.js");

  const noop = () => {};
  const vector = Array.from({ length: 1536 }, (_, i) => Math.sin(i * 0.01));
  const rows = Array.from({ length: 3 }, (_, i) => ({
    PAGE_CONTENT: "Document chunk " + (i + 1) + ": Relevant content.",
    SCORE: parseFloat((0.95 - i * 0.05).toFixed(2)),
  }));

  require.cache[cdsPath] = { id: cdsPath, filename: cdsPath, loaded: true, exports: {
    db: { run: () => Promise.resolve(rows), kind: "hana" },
    connect: { to: () => Promise.resolve({ run: () => Promise.resolve(rows) }) },
    services: {},
    log: () => ({ debug: noop, info: noop, warn: noop, error: noop }),
    Service: class { async init() {} },
    once: noop, env: { requires: {} }, requires: {},
  }};

  const content = "This is a mock AI response.";
  require.cache[sdkPath] = { id: sdkPath, filename: sdkPath, loaded: true, exports: {
    OrchestrationEmbeddingClient: function () { this.embed = () => Promise.resolve({ getEmbeddings: () => [{ embedding: vector }] }); },
    OrchestrationClient: function () {
      this.chatCompletion = () => Promise.resolve({
        getContent: () => content, getTokenUsage: () => ({ completion_tokens: 42, prompt_tokens: 100, total_tokens: 142 }), getFinishReason: () => "stop",
        data: { orchestration_result: { choices: [{ message: { role: "assistant", content }, finish_reason: "stop" }], usage: { completion_tokens: 42, prompt_tokens: 100, total_tokens: 142 } } },
      });
    },
    buildAzureContentSafetyFilter: (c) => ({ type: "azure_content_safety", config: c || { Hate: 2, Violence: 2, SelfHarm: 2, Sexual: 2 } }),
  }};

  require.cache[anonPath] = { id: anonPath, filename: anonPath, loaded: true, exports: {
    VALID_ANONYMIZATION_ALGORITHM_PREFIXES: ["K-Anonymity", "Differential-Privacy", "L-Diversity"],
  }};

  const Plugin = require("../../srv/cap-llm-plugin.js");
  const app = createApp(new Plugin());
  startServer(app);
}

module.exports = { createApp, startServer };
