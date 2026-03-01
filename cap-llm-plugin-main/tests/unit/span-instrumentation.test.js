// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Unit tests for OTel span instrumentation (Day 52).
 *
 * Verifies that every public CAPLLMPlugin method:
 *   1. Starts a span with the correct name
 *   2. Sets the expected attributes
 *   3. Emits the expected events on success
 *   4. Records exceptions and sets ERROR status on failure
 *   5. Always calls span.end() (via finally)
 *
 * Strategy: use jest.doMock() (not hoisted) inside setupPlugin() to inject
 * a fresh spy tracer before each test, then require the plugin fresh.
 */

"use strict";

// ════════════════════════════════════════════════════════════════════
// Spy tracer factory
// ════════════════════════════════════════════════════════════════════

function makeSpan() {
  return {
    setAttribute: jest.fn(),
    addEvent: jest.fn(),
    recordException: jest.fn(),
    setStatus: jest.fn(),
    end: jest.fn(),
    _name: null,
  };
}

function makeTracer() {
  const spans = [];
  return {
    startSpan: jest.fn((name) => {
      const span = makeSpan();
      span._name = name;
      spans.push(span);
      return span;
    }),
    spans,
    lastSpan: () => spans[spans.length - 1],
  };
}

// ════════════════════════════════════════════════════════════════════
// Module setup helpers
// ════════════════════════════════════════════════════════════════════

const vector = Array.from({ length: 1536 }, (_, i) => Math.sin(i * 0.01));
const defaultEmbedResponse = { getEmbeddings: () => [{ embedding: vector }] };
const defaultChatResponse = {
  getContent: () => "Hello!",
  getTokenUsage: () => ({ total_tokens: 42 }),
  getFinishReason: () => "stop",
  data: { orchestration_result: { choices: [{ message: { content: "Hello!" } }] } },
};
const rows = [{ PAGE_CONTENT: "doc1", SCORE: 0.95 }, { PAGE_CONTENT: "doc2", SCORE: 0.85 }];

let mockEmbedFn = jest.fn().mockResolvedValue(defaultEmbedResponse);
let mockChatFn = jest.fn().mockResolvedValue(defaultChatResponse);
let mockFilterFn = jest.fn().mockReturnValue({ type: "azure_content_safety" });

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: (...a) => mockEmbedFn(...a) })),
  OrchestrationClient: jest.fn().mockImplementation(() => ({ chatCompletion: (...a) => mockChatFn(...a) })),
  get buildAzureContentSafetyFilter() { return mockFilterFn; },
}));

jest.mock("@sap/cds", () => ({
  Service: class { async init() {} },
  connect: { to: jest.fn().mockResolvedValue({ run: jest.fn().mockResolvedValue(rows) }) },
  db: { run: jest.fn().mockResolvedValue([{ NAME: "Alice" }]) },
  log: () => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() }),
  once: jest.fn(),
  env: { requires: {} },
  requires: {},
  services: {
    EmployeeService: {
      entities: {
        Employees: {
          name: "Employees",
          elements: {
            ID: { "@anonymize": "is_sequence", name: "ID" },
            NAME: { name: "NAME" },
          },
        },
      },
    },
  },
}), { virtual: true });

jest.mock("../../lib/validation-utils", () => ({
  validateSqlIdentifier: jest.fn(),
  validatePositiveInteger: jest.fn(),
  validateEmbeddingVector: jest.fn(),
}));

jest.mock("../../srv/legacy", () => ({
  getEmbedding: jest.fn(),
  getChatCompletion: jest.fn(),
  getRagResponse: jest.fn(),
}));

let Plugin;
let tracer;

function setupPlugin(sdkOverrides = {}) {
  jest.resetModules();
  tracer = makeTracer();
  const mockCapturedTracer = tracer;

  mockEmbedFn = sdkOverrides.embed ?? jest.fn().mockResolvedValue(defaultEmbedResponse);
  mockChatFn = sdkOverrides.chatCompletion ?? jest.fn().mockResolvedValue(defaultChatResponse);
  mockFilterFn = sdkOverrides.buildAzureContentSafetyFilter ?? jest.fn().mockReturnValue({ type: "azure_content_safety" });

  jest.doMock("../../src/telemetry/tracer", () => ({
    getTracer: () => mockCapturedTracer,
    SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
    _resetTracerCache: jest.fn(),
  }));
  Plugin = require("../../srv/cap-llm-plugin.js");
  return new Plugin();
}

const embConfig = { modelName: "ada-002", resourceGroup: "default", deploymentUrl: "https://x.com" };
const chatConfig = { modelName: "gpt-4o", resourceGroup: "default" };
const embedding = Array.from({ length: 1536 }, (_, i) => Math.sin(i * 0.01));

// ════════════════════════════════════════════════════════════════════
// getEmbeddingWithConfig
// ════════════════════════════════════════════════════════════════════

describe("getEmbeddingWithConfig — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });
  test("starts span with correct name", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getEmbeddingWithConfig");
  });

  test("sets llm.embedding.model attribute", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    const span = tracer.lastSpan();
    expect(span.setAttribute).toHaveBeenCalledWith("llm.embedding.model", "ada-002");
  });

  test("sets llm.resource_group attribute", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    const span = tracer.lastSpan();
    expect(span.setAttribute).toHaveBeenCalledWith("llm.resource_group", "default");
  });

  test("adds embedding_response_received event on success", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    expect(tracer.lastSpan().addEvent).toHaveBeenCalledWith("embedding_response_received");
  });

  test("sets OK status on success", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("calls span.end() on success", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hello");
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and sets ERROR on config validation failure", async () => {
    await expect(plugin.getEmbeddingWithConfig({ resourceGroup: "rg" }, "hi")).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });

  test("records exception and sets ERROR on SDK failure", async () => {
    const sdkError = new Error("AI Core 503");
    plugin = setupPlugin({ embed: jest.fn().mockRejectedValue(sdkError) });
    await expect(plugin.getEmbeddingWithConfig(embConfig, "hi")).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// getChatCompletionWithConfig
// ════════════════════════════════════════════════════════════════════

describe("getChatCompletionWithConfig — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("starts span with correct name", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getChatCompletionWithConfig");
  });

  test("sets llm.chat.model and llm.resource_group attributes", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    const span = tracer.lastSpan();
    expect(span.setAttribute).toHaveBeenCalledWith("llm.chat.model", "gpt-4o");
    expect(span.setAttribute).toHaveBeenCalledWith("llm.resource_group", "default");
  });

  test("adds chat_completion_response_received event on success", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    expect(tracer.lastSpan().addEvent).toHaveBeenCalledWith("chat_completion_response_received");
  });

  test("sets OK status on success", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("calls span.end() on success", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR status on config validation failure", async () => {
    await expect(plugin.getChatCompletionWithConfig({ resourceGroup: "rg" }, {})).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR on SDK failure", async () => {
    plugin = setupPlugin({ chatCompletion: jest.fn().mockRejectedValue(new Error("rate limit")) });
    await expect(plugin.getChatCompletionWithConfig(chatConfig, { messages: [] })).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// similaritySearch
// ════════════════════════════════════════════════════════════════════

describe("similaritySearch — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("starts span with correct name", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.similaritySearch");
  });

  test("sets db.hana.table, algo, top_k, embedding_dims attributes", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    const span = tracer.lastSpan();
    expect(span.setAttribute).toHaveBeenCalledWith("db.hana.table", "DOCS");
    expect(span.setAttribute).toHaveBeenCalledWith("db.hana.algo", "COSINE_SIMILARITY");
    expect(span.setAttribute).toHaveBeenCalledWith("db.hana.top_k", 3);
    expect(span.setAttribute).toHaveBeenCalledWith("db.hana.embedding_dims", embedding.length);
  });

  test("adds similarity_search_completed event on success", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    expect(tracer.lastSpan().addEvent).toHaveBeenCalledWith(
      "similarity_search_completed",
      expect.objectContaining({ "search.result_count": expect.any(Number) })
    );
  });

  test("sets OK status on success", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("calls span.end() on success", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR on DB failure", async () => {
    const cds = require("@sap/cds");
    cds.connect.to.mockRejectedValueOnce(new Error("DB connection failed"));
    await expect(
      plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3)
    ).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// getHarmonizedChatCompletion
// ════════════════════════════════════════════════════════════════════

describe("getHarmonizedChatCompletion — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  const params = {
    clientConfig: { promptTemplating: { model: { name: "gpt-4o" } } },
    chatCompletionConfig: { messages: [{ role: "user", content: "hi" }] },
  };

  test("starts span with correct name", async () => {
    await plugin.getHarmonizedChatCompletion(params);
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getHarmonizedChatCompletion");
  });

  test("sets flag attributes", async () => {
    await plugin.getHarmonizedChatCompletion({ ...params, getContent: true });
    const span = tracer.lastSpan();
    expect(span.setAttribute).toHaveBeenCalledWith("llm.harmonized.get_content", true);
    expect(span.setAttribute).toHaveBeenCalledWith("llm.harmonized.get_token_usage", false);
    expect(span.setAttribute).toHaveBeenCalledWith("llm.harmonized.get_finish_reason", false);
  });

  test("adds harmonized_chat_completion_received event on success", async () => {
    await plugin.getHarmonizedChatCompletion(params);
    expect(tracer.lastSpan().addEvent).toHaveBeenCalledWith("harmonized_chat_completion_received");
  });

  test("sets OK status on success", async () => {
    await plugin.getHarmonizedChatCompletion(params);
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("calls span.end() on success", async () => {
    await plugin.getHarmonizedChatCompletion(params);
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR on SDK failure", async () => {
    plugin = setupPlugin({ chatCompletion: jest.fn().mockRejectedValue(new Error("upstream error")) });
    await expect(plugin.getHarmonizedChatCompletion(params)).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// getContentFilters
// ════════════════════════════════════════════════════════════════════

describe("getContentFilters — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("starts span with correct name", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getContentFilters");
  });

  test("sets content_filter.type attribute", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("content_filter.type", "azure");
  });

  test("adds content_filter_built event on success", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.lastSpan().addEvent).toHaveBeenCalledWith("content_filter_built");
  });

  test("sets OK status on success", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("calls span.end() on success", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR on unsupported type", async () => {
    await expect(plugin.getContentFilters({ type: "openai", config: {} })).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// getAnonymizedData
// ════════════════════════════════════════════════════════════════════

describe("getAnonymizedData — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("starts span with correct name", async () => {
    await plugin.getAnonymizedData("EmployeeService.Employees", []);
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getAnonymizedData");
  });

  test("sets anonymization.entity attribute", async () => {
    await plugin.getAnonymizedData("EmployeeService.Employees", []);
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith(
      "anonymization.entity", "EmployeeService.Employees"
    );
  });

  test("sets anonymization.sequence_id_count attribute", async () => {
    await plugin.getAnonymizedData("EmployeeService.Employees", [1, 2, 3]);
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("anonymization.sequence_id_count", 3);
  });

  test("calls span.end() on success", async () => {
    await plugin.getAnonymizedData("EmployeeService.Employees", []);
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("records exception and ERROR on entity not found", async () => {
    await expect(plugin.getAnonymizedData("Unknown.Entity", [])).rejects.toThrow();
    const span = tracer.lastSpan();
    expect(span.recordException).toHaveBeenCalled();
    expect(span.setStatus).toHaveBeenCalledWith(expect.objectContaining({ code: 2 }));
    expect(span.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// getRagResponseWithConfig — verify existing span still works
// ════════════════════════════════════════════════════════════════════

describe("getRagResponseWithConfig — span instrumentation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("starts span with correct name", async () => {
    await plugin.getRagResponseWithConfig(
      "query", "DOCS", "EMBED", "CONTENT", "Answer:", embConfig, chatConfig
    );
    expect(tracer.startSpan).toHaveBeenCalledWith("cap-llm-plugin.getRagResponseWithConfig");
  });

  test("sets all expected attributes", async () => {
    await plugin.getRagResponseWithConfig(
      "query", "DOCS", "EMBED", "CONTENT", "Answer:", embConfig, chatConfig
    );
    const ragSpan = tracer.spans.find(s => s._name === "cap-llm-plugin.getRagResponseWithConfig");
    expect(ragSpan.setAttribute).toHaveBeenCalledWith("llm.embedding.model", "ada-002");
    expect(ragSpan.setAttribute).toHaveBeenCalledWith("llm.chat.model", "gpt-4o");
    expect(ragSpan.setAttribute).toHaveBeenCalledWith("db.hana.table", "DOCS");
    expect(ragSpan.setAttribute).toHaveBeenCalledWith("db.hana.algo", "COSINE_SIMILARITY");
    expect(ragSpan.setAttribute).toHaveBeenCalledWith("llm.rag.top_k", 3);
  });

  test("emits embedding_generated, similarity_search_completed, chat_completion_received events", async () => {
    await plugin.getRagResponseWithConfig(
      "query", "DOCS", "EMBED", "CONTENT", "Answer:", embConfig, chatConfig
    );
    const ragSpan = tracer.spans.find(s => s._name === "cap-llm-plugin.getRagResponseWithConfig");
    const eventNames = ragSpan.addEvent.mock.calls.map(([name]) => name);
    expect(eventNames).toContain("embedding_generated");
    expect(eventNames).toContain("similarity_search_completed");
    expect(eventNames).toContain("chat_completion_received");
  });

  test("calls span.end() on success", async () => {
    await plugin.getRagResponseWithConfig(
      "query", "DOCS", "EMBED", "CONTENT", "Answer:", embConfig, chatConfig
    );
    const ragSpan = tracer.spans.find(s => s._name === "cap-llm-plugin.getRagResponseWithConfig");
    expect(ragSpan.end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// span.end() called exactly once for every method (no double-end)
// ════════════════════════════════════════════════════════════════════

describe("span.end() called exactly once per method invocation", () => {
  let plugin;
  beforeEach(() => { plugin = setupPlugin(); });

  test("getEmbeddingWithConfig success: end called once", async () => {
    await plugin.getEmbeddingWithConfig(embConfig, "hi");
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getEmbeddingWithConfig error: end called once", async () => {
    await expect(plugin.getEmbeddingWithConfig({}, "hi")).rejects.toThrow();
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getChatCompletionWithConfig success: end called once", async () => {
    await plugin.getChatCompletionWithConfig(chatConfig, { messages: [] });
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getChatCompletionWithConfig error: end called once", async () => {
    await expect(plugin.getChatCompletionWithConfig({}, {})).rejects.toThrow();
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("similaritySearch success: end called once", async () => {
    await plugin.similaritySearch("DOCS", "EMBED", "CONTENT", embedding, "COSINE_SIMILARITY", 3);
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getHarmonizedChatCompletion success: end called once", async () => {
    await plugin.getHarmonizedChatCompletion({
      clientConfig: {}, chatCompletionConfig: { messages: [] },
    });
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getContentFilters success: end called once", async () => {
    await plugin.getContentFilters({ type: "azure", config: {} });
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getContentFilters unsupported type error: end called once", async () => {
    await expect(plugin.getContentFilters({ type: "openai", config: {} })).rejects.toThrow();
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("getAnonymizedData success: end called once", async () => {
    await plugin.getAnonymizedData("EmployeeService.Employees", []);
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });
});
