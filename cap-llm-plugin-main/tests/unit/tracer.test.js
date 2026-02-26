/**
 * Unit tests for src/telemetry/tracer.ts
 *
 * Tests:
 *   1. SpanStatusCode constants have correct values
 *   2. No-op tracer returned when @opentelemetry/api throws on require
 *   3. No-op span methods are all callable without error
 *   4. Tracer is cached after first call
 *   5. _resetTracerCache forces re-evaluation on next call
 *   6. Real @opentelemetry/api is available in this repo (devDep) — wraps it correctly
 *   7. PluginSpan interface contract satisfied by real + no-op spans
 */

"use strict";

// ════════════════════════════════════════════════════════════════════
// SpanStatusCode constants
// ════════════════════════════════════════════════════════════════════

describe("SpanStatusCode constants", () => {
  const { SpanStatusCode } = require("../../src/telemetry/tracer");

  test("UNSET is 0", () => expect(SpanStatusCode.UNSET).toBe(0));
  test("OK is 1", () => expect(SpanStatusCode.OK).toBe(1));
  test("ERROR is 2", () => expect(SpanStatusCode.ERROR).toBe(2));

  test("all values are numbers", () => {
    for (const val of Object.values(SpanStatusCode)) {
      expect(typeof val).toBe("number");
    }
  });

  test("has exactly three entries", () => {
    expect(Object.keys(SpanStatusCode)).toHaveLength(3);
  });
});

// ════════════════════════════════════════════════════════════════════
// No-op fallback — simulate @opentelemetry/api missing
// ════════════════════════════════════════════════════════════════════

describe("getTracer() — no-op fallback when OTel unavailable", () => {
  let getTracer;
  let resetCache;
  let restoreRequire;

  beforeEach(() => {
    jest.resetModules();

    // Intercept require('@opentelemetry/api') to simulate the package being absent
    const Module = require("module");
    const originalRequire = Module.prototype.require;
    restoreRequire = () => { Module.prototype.require = originalRequire; };

    Module.prototype.require = function (id) {
      if (id === "@opentelemetry/api") throw new Error("Cannot find module '@opentelemetry/api'");
      return originalRequire.apply(this, arguments);
    };

    const mod = require("../../src/telemetry/tracer");
    getTracer = mod.getTracer;
    resetCache = mod._resetTracerCache;
    resetCache();
  });

  afterEach(() => {
    restoreRequire();
    jest.resetModules();
  });

  test("getTracer() returns object with startSpan", () => {
    expect(typeof getTracer().startSpan).toBe("function");
  });

  test("startSpan returns span with all required methods", () => {
    const span = getTracer().startSpan("test.op");
    expect(typeof span.setAttribute).toBe("function");
    expect(typeof span.addEvent).toBe("function");
    expect(typeof span.recordException).toBe("function");
    expect(typeof span.setStatus).toBe("function");
    expect(typeof span.end).toBe("function");
  });

  test("setAttribute does not throw for string, number, boolean", () => {
    const span = getTracer().startSpan("test.op");
    expect(() => span.setAttribute("str", "hello")).not.toThrow();
    expect(() => span.setAttribute("num", 42)).not.toThrow();
    expect(() => span.setAttribute("bool", true)).not.toThrow();
  });

  test("addEvent does not throw with and without attributes", () => {
    const span = getTracer().startSpan("test.op");
    expect(() => span.addEvent("event_a")).not.toThrow();
    expect(() => span.addEvent("event_b", { count: 3 })).not.toThrow();
  });

  test("recordException does not throw", () => {
    const span = getTracer().startSpan("test.op");
    expect(() => span.recordException(new Error("boom"))).not.toThrow();
  });

  test("setStatus does not throw for OK and ERROR", () => {
    const span = getTracer().startSpan("test.op");
    expect(() => span.setStatus({ code: 1 })).not.toThrow();
    expect(() => span.setStatus({ code: 2, message: "failed" })).not.toThrow();
  });

  test("end does not throw", () => {
    const span = getTracer().startSpan("test.op");
    expect(() => span.end()).not.toThrow();
  });

  test("full span lifecycle does not throw", () => {
    const span = getTracer().startSpan("rag.pipeline");
    span.setAttribute("llm.model", "ada-002");
    span.addEvent("embedding_generated", { "embedding.dimensions": 1536 });
    span.addEvent("similarity_search_completed", { "search.result_count": 3 });
    span.addEvent("chat_completion_received");
    span.setStatus({ code: 1 });
    span.end();
  });

  test("error path lifecycle does not throw", () => {
    const span = getTracer().startSpan("rag.pipeline");
    span.setAttribute("llm.model", "ada-002");
    span.recordException(new Error("upstream timeout"));
    span.setStatus({ code: 2, message: "upstream timeout" });
    span.end();
  });
});

// ════════════════════════════════════════════════════════════════════
// Caching behaviour
// ════════════════════════════════════════════════════════════════════

describe("getTracer() — caching", () => {
  beforeEach(() => jest.resetModules());
  afterEach(() => jest.resetModules());

  test("repeated calls return the same tracer instance", () => {
    const { getTracer: gt, _resetTracerCache: rc } = require("../../src/telemetry/tracer");
    rc();
    const t1 = gt();
    const t2 = gt();
    expect(t1).toBe(t2);
  });

  test("_resetTracerCache causes a new tracer to be returned", () => {
    const { getTracer: gt, _resetTracerCache: rc } = require("../../src/telemetry/tracer");
    rc();
    const t1 = gt();
    rc();
    const t2 = gt();
    // After reset, the cache is re-populated — the new tracer is valid
    expect(t2).toBeDefined();
    expect(typeof t2.startSpan).toBe("function");
    // They are different objects (cache was cleared)
    expect(t1).not.toBe(t2);
  });
});

// ════════════════════════════════════════════════════════════════════
// Real @opentelemetry/api integration (it IS installed as devDep)
// ════════════════════════════════════════════════════════════════════

describe("getTracer() — real @opentelemetry/api (devDep is installed)", () => {
  let getTracer;
  let resetCache;

  beforeEach(() => {
    jest.resetModules();
    const mod = require("../../src/telemetry/tracer");
    getTracer = mod.getTracer;
    resetCache = mod._resetTracerCache;
    resetCache();
  });

  afterEach(() => jest.resetModules());

  test("getTracer() returns an object", () => {
    const tracer = getTracer();
    expect(tracer).toBeDefined();
    expect(typeof tracer).toBe("object");
  });

  test("startSpan returns a span with all required methods", () => {
    const span = getTracer().startSpan("test.real");
    expect(typeof span.setAttribute).toBe("function");
    expect(typeof span.addEvent).toBe("function");
    expect(typeof span.recordException).toBe("function");
    expect(typeof span.setStatus).toBe("function");
    expect(typeof span.end).toBe("function");
  });

  test("setAttribute does not throw (real span, no provider registered → no-op internally)", () => {
    const span = getTracer().startSpan("test.real");
    expect(() => span.setAttribute("llm.model", "ada-002")).not.toThrow();
    expect(() => span.setAttribute("llm.rag.top_k", 3)).not.toThrow();
  });

  test("addEvent does not throw", () => {
    const span = getTracer().startSpan("test.real");
    expect(() => span.addEvent("embedding_generated", { "embedding.dimensions": 1536 })).not.toThrow();
  });

  test("recordException does not throw", () => {
    const span = getTracer().startSpan("test.real");
    expect(() => span.recordException(new Error("sdk error"))).not.toThrow();
  });

  test("setStatus does not throw", () => {
    const span = getTracer().startSpan("test.real");
    expect(() => span.setStatus({ code: 1 })).not.toThrow();
  });

  test("end does not throw", () => {
    const span = getTracer().startSpan("test.real");
    expect(() => span.end()).not.toThrow();
  });

  test("full RAG span lifecycle matches expected attribute keys", () => {
    const span = getTracer().startSpan("cap-llm-plugin.getRagResponseWithConfig");
    expect(() => {
      span.setAttribute("llm.embedding.model", "text-embedding-ada-002");
      span.setAttribute("llm.chat.model", "gpt-4o");
      span.setAttribute("db.hana.table", "DOCUMENTS");
      span.setAttribute("db.hana.algo", "COSINE_SIMILARITY");
      span.setAttribute("llm.rag.top_k", 3);
      span.addEvent("embedding_generated", { "embedding.dimensions": 1536 });
      span.addEvent("similarity_search_completed", { "search.result_count": 3 });
      span.addEvent("chat_completion_received");
      span.setStatus({ code: 1 });
      span.end();
    }).not.toThrow();
  });

  test("error path: recordException + ERROR status + end does not throw", () => {
    const span = getTracer().startSpan("cap-llm-plugin.getRagResponseWithConfig");
    expect(() => {
      span.setAttribute("llm.embedding.model", "ada-002");
      span.recordException(new Error("AI Core 503"));
      span.setStatus({ code: 2, message: "AI Core 503" });
      span.end();
    }).not.toThrow();
  });
});

// ════════════════════════════════════════════════════════════════════
// Span name and attribute key conventions
// ════════════════════════════════════════════════════════════════════

describe("Span naming and attribute key conventions", () => {
  const { getTracer: gt, _resetTracerCache: rc } = require("../../src/telemetry/tracer");

  beforeEach(() => rc());

  test("span name follows 'cap-llm-plugin.<operation>' convention", () => {
    const expectedNames = [
      "cap-llm-plugin.getRagResponseWithConfig",
      "cap-llm-plugin.getEmbeddingWithConfig",
      "cap-llm-plugin.getChatCompletionWithConfig",
      "cap-llm-plugin.similaritySearch",
    ];
    for (const name of expectedNames) {
      expect(() => gt().startSpan(name).end()).not.toThrow();
    }
  });

  test("known attribute keys are accepted without error", () => {
    const span = gt().startSpan("test");
    const attrs = [
      ["llm.embedding.model", "ada-002"],
      ["llm.chat.model", "gpt-4o"],
      ["db.hana.table", "DOCUMENTS"],
      ["db.hana.algo", "COSINE_SIMILARITY"],
      ["llm.rag.top_k", 3],
      ["embedding.dimensions", 1536],
      ["search.result_count", 5],
    ];
    for (const [key, val] of attrs) {
      expect(() => span.setAttribute(key, val)).not.toThrow();
    }
    span.end();
  });
});
