// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Unit tests for createOtelMiddleware (Day 53).
 *
 * Verifies:
 *   1. Span is started with the correct name
 *   2. Attributes set from options + middleware context
 *   3. ai_core.request_sent event emitted before fn()
 *   4. ai_core.response_received event + http.status_code on success
 *   5. setStatus(OK) for 2xx, setStatus(ERROR) for 4xx/5xx
 *   6. recordException + setStatus(ERROR) when fn() throws
 *   7. span.end() called exactly once in all paths
 *   8. traceparent header injected when @opentelemetry/api is available
 *   9. Transparent pass-through when @opentelemetry/api absent
 *  10. Default span name when no endpoint provided
 */

"use strict";

// ════════════════════════════════════════════════════════════════════
// Spy tracer helpers (same pattern as span-instrumentation tests)
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
// Module setup
// ════════════════════════════════════════════════════════════════════

let createOtelMiddleware;
let tracer;

function loadMiddleware(otelAvailable = false) {
  tracer = makeTracer();
  const mockCapturedTracer = tracer;

  jest.isolateModules(() => {
    jest.doMock("../../src/telemetry/tracer", () => ({
      getTracer: () => mockCapturedTracer,
      SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
    }));

    if (otelAvailable) {
      const mockInject = jest.fn((ctx, carrier) => {
        carrier["traceparent"] = "00-abc123-def456-01";
      });
      jest.doMock("@opentelemetry/api", () => ({
        propagation: { inject: mockInject },
        context: { active: jest.fn().mockReturnValue({}) },
        _mockInject: mockInject,
      }));
    } else {
      jest.doMock("@opentelemetry/api", () => {
        throw Object.assign(new Error("Cannot find module '@opentelemetry/api'"), {
          code: "MODULE_NOT_FOUND",
        });
      });
    }

    ({ createOtelMiddleware } = require("../../src/telemetry/ai-sdk-middleware"));
  });
}

// Helper to build a MiddlewareOptions object
function makeMiddlewareOptions({ uri = "https://ai.core.example/chat", overrideFn } = {}) {
  return {
    fn: overrideFn ?? jest.fn().mockResolvedValue({ status: 200, data: { result: "ok" } }),
    context: {
      tenantId: "tenant-abc",
      uri,
      destinationName: "aicore-prod",
    },
  };
}

afterEach(() => jest.resetModules());

// ════════════════════════════════════════════════════════════════════
// Span naming
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — span naming", () => {
  beforeEach(() => loadMiddleware());

  test("uses endpoint in span name when provided", async () => {
    const middleware = createOtelMiddleware({ endpoint: "/chat/completions" });
    const opts = makeMiddlewareOptions();
    await middleware(opts)({});
    expect(tracer.lastSpan()._name).toBe("HTTP POST /chat/completions");
  });

  test("uses generic name when no endpoint provided", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    await middleware(opts)({});
    expect(tracer.lastSpan()._name).toBe("HTTP POST ai-core");
  });

  test("different endpoints produce different span names", async () => {
    const m1 = createOtelMiddleware({ endpoint: "/embeddings" });
    const m2 = createOtelMiddleware({ endpoint: "/chat/completions" });
    await m1(makeMiddlewareOptions())({});
    await m2(makeMiddlewareOptions())({});
    expect(tracer.spans[0]._name).toBe("HTTP POST /embeddings");
    expect(tracer.spans[1]._name).toBe("HTTP POST /chat/completions");
  });
});

// ════════════════════════════════════════════════════════════════════
// Attributes
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — attributes", () => {
  beforeEach(() => loadMiddleware());

  test("always sets http.method = POST", async () => {
    const middleware = createOtelMiddleware();
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("http.method", "POST");
  });

  test("sets ai_core.endpoint when provided", async () => {
    const middleware = createOtelMiddleware({ endpoint: "/embeddings" });
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("ai_core.endpoint", "/embeddings");
  });

  test("sets ai_core.resource_group when provided", async () => {
    const middleware = createOtelMiddleware({ resourceGroup: "my-rg" });
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("ai_core.resource_group", "my-rg");
  });

  test("sets ai_core.api_version when provided", async () => {
    const middleware = createOtelMiddleware({ apiVersion: "2024-02-01" });
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("ai_core.api_version", "2024-02-01");
  });

  test("sets http.url from context.uri", async () => {
    const middleware = createOtelMiddleware();
    await middleware(makeMiddlewareOptions({ uri: "https://ai.example.com/v2/chat" }))({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("http.url", "https://ai.example.com/v2/chat");
  });

  test("sets ai_core.destination from context.destinationName", async () => {
    const middleware = createOtelMiddleware();
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("ai_core.destination", "aicore-prod");
  });

  test("sets http.status_code from response", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 200, data: {} });
    await middleware(opts)({});
    expect(tracer.lastSpan().setAttribute).toHaveBeenCalledWith("http.status_code", 200);
  });

  test("does NOT set ai_core.endpoint when not provided", async () => {
    const middleware = createOtelMiddleware({});
    await middleware(makeMiddlewareOptions())({});
    const setCalls = tracer.lastSpan().setAttribute.mock.calls.map(([k]) => k);
    expect(setCalls).not.toContain("ai_core.endpoint");
  });
});

// ════════════════════════════════════════════════════════════════════
// Events
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — events", () => {
  beforeEach(() => loadMiddleware());

  test("emits ai_core.request_sent before calling fn()", async () => {
    const callOrder = [];
    const middleware = createOtelMiddleware({ endpoint: "/chat/completions" });
    const opts = {
      fn: jest.fn().mockImplementation(async () => {
        callOrder.push("fn");
        return { status: 200, data: {} };
      }),
      context: { uri: "https://ai.example.com" },
    };

    const span = { setAttribute: jest.fn(), addEvent: jest.fn().mockImplementation((name) => {
      callOrder.push(name);
    }), recordException: jest.fn(), setStatus: jest.fn(), end: jest.fn(), _name: null };
    tracer.startSpan.mockReturnValueOnce(span);

    await middleware(opts)({});
    const requestSentIdx = callOrder.indexOf("ai_core.request_sent");
    const fnIdx = callOrder.indexOf("fn");
    expect(requestSentIdx).toBeGreaterThanOrEqual(0);
    expect(fnIdx).toBeGreaterThan(requestSentIdx);
  });

  test("emits ai_core.response_received after fn() returns", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    await middleware(opts)({});
    const events = tracer.lastSpan().addEvent.mock.calls.map(([name]) => name);
    expect(events).toContain("ai_core.response_received");
  });

  test("ai_core.response_received carries http.status_code attribute", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 201, data: {} });
    await middleware(opts)({});
    const responseEvent = tracer.lastSpan().addEvent.mock.calls.find(([n]) => n === "ai_core.response_received");
    expect(responseEvent[1]).toEqual(expect.objectContaining({ "http.status_code": 201 }));
  });
});

// ════════════════════════════════════════════════════════════════════
// Status codes
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — span status", () => {
  beforeEach(() => loadMiddleware());

  test("sets OK status for HTTP 200", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 200 });
    await middleware(opts)({});
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("sets OK status for HTTP 201", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 201 });
    await middleware(opts)({});
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("sets ERROR status for HTTP 400", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 400 });
    await middleware(opts)({});
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith(
      expect.objectContaining({ code: 2 })
    );
  });

  test("sets ERROR status for HTTP 429", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 429 });
    await middleware(opts)({});
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith(
      expect.objectContaining({ code: 2, message: "HTTP 429" })
    );
  });

  test("sets ERROR status for HTTP 503", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 503 });
    await middleware(opts)({});
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith(
      expect.objectContaining({ code: 2 })
    );
  });

  test("records exception when fn() throws", async () => {
    const middleware = createOtelMiddleware();
    const err = new Error("Connection refused");
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockRejectedValue(err) });
    await expect(middleware(opts)({})).rejects.toThrow("Connection refused");
    expect(tracer.lastSpan().recordException).toHaveBeenCalledWith(err);
  });

  test("sets ERROR status when fn() throws", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockRejectedValue(new Error("oops")) });
    await expect(middleware(opts)({})).rejects.toThrow();
    expect(tracer.lastSpan().setStatus).toHaveBeenCalledWith(
      expect.objectContaining({ code: 2 })
    );
  });

  test("re-throws the original error when fn() throws", async () => {
    const middleware = createOtelMiddleware();
    const err = new Error("AI Core 500");
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockRejectedValue(err) });
    await expect(middleware(opts)({})).rejects.toBe(err);
  });
});

// ════════════════════════════════════════════════════════════════════
// span.end() always called exactly once
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — span.end() lifecycle", () => {
  beforeEach(() => loadMiddleware());

  test("span.end() called once on 200 success", async () => {
    const middleware = createOtelMiddleware();
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("span.end() called once on 4xx response", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    opts.fn = jest.fn().mockResolvedValue({ status: 401 });
    await middleware(opts)({});
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("span.end() called once when fn() throws", async () => {
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockRejectedValue(new Error("boom")) });
    await expect(middleware(opts)({})).rejects.toThrow();
    expect(tracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// W3C trace context propagation
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — traceparent injection", () => {
  test("injects traceparent header when @opentelemetry/api is available", async () => {
    loadMiddleware(true);
    const middleware = createOtelMiddleware({ endpoint: "/chat/completions" });
    const capturedConfigs = [];
    const opts = {
      fn: jest.fn().mockImplementation(async (cfg) => {
        capturedConfigs.push(cfg);
        return { status: 200, data: {} };
      }),
      context: { uri: "https://ai.example.com" },
    };
    await middleware(opts)({});
    expect(capturedConfigs[0].headers).toBeDefined();
    expect(capturedConfigs[0].headers["traceparent"]).toBe("00-abc123-def456-01");
  });

  test("preserves existing headers when injecting traceparent", async () => {
    loadMiddleware(true);
    const middleware = createOtelMiddleware();
    const capturedConfigs = [];
    const opts = {
      fn: jest.fn().mockImplementation(async (cfg) => {
        capturedConfigs.push(cfg);
        return { status: 200, data: {} };
      }),
      context: {},
    };
    await middleware(opts)({ headers: { "content-type": "application/json" } });
    expect(capturedConfigs[0].headers["content-type"]).toBe("application/json");
    expect(capturedConfigs[0].headers["traceparent"]).toBeDefined();
  });

  test("passes through config unchanged when @opentelemetry/api not installed", async () => {
    loadMiddleware(false); // no OTel
    const middleware = createOtelMiddleware();
    const capturedConfigs = [];
    const opts = {
      fn: jest.fn().mockImplementation(async (cfg) => {
        capturedConfigs.push(cfg);
        return { status: 200, data: {} };
      }),
      context: {},
    };
    const inputConfig = { headers: { "x-custom": "value" }, method: "POST" };
    await middleware(opts)(inputConfig);
    // Original input config values should be preserved
    expect(capturedConfigs[0].headers["x-custom"]).toBe("value");
    // No traceparent injected
    expect(capturedConfigs[0].headers["traceparent"]).toBeUndefined();
  });

  test("does not throw when requestConfig has no headers property", async () => {
    loadMiddleware(true);
    const middleware = createOtelMiddleware();
    const opts = makeMiddlewareOptions();
    await expect(middleware(opts)({})).resolves.not.toThrow();
  });
});

// ════════════════════════════════════════════════════════════════════
// Return value passthrough
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — response passthrough", () => {
  beforeEach(() => loadMiddleware());

  test("returns the response from fn() unchanged", async () => {
    const middleware = createOtelMiddleware();
    const expectedResponse = { status: 200, data: { answer: "42" } };
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockResolvedValue(expectedResponse) });
    const result = await middleware(opts)({});
    expect(result).toBe(expectedResponse);
  });

  test("returns the fn() result for non-2xx that did not throw", async () => {
    const middleware = createOtelMiddleware();
    const response = { status: 400, data: { error: "Bad Request" } };
    const opts = makeMiddlewareOptions({ overrideFn: jest.fn().mockResolvedValue(response) });
    const result = await middleware(opts)({});
    expect(result).toBe(response);
  });
});

// ════════════════════════════════════════════════════════════════════
// Factory reuse — each call to createOtelMiddleware is independent
// ════════════════════════════════════════════════════════════════════

describe("createOtelMiddleware — factory independence", () => {
  beforeEach(() => loadMiddleware());

  test("two middleware instances create separate spans", async () => {
    const m1 = createOtelMiddleware({ endpoint: "/embeddings", resourceGroup: "rg-a" });
    const m2 = createOtelMiddleware({ endpoint: "/chat/completions", resourceGroup: "rg-b" });
    await m1(makeMiddlewareOptions())({});
    await m2(makeMiddlewareOptions())({});
    expect(tracer.spans).toHaveLength(2);
    expect(tracer.spans[0]._name).toBe("HTTP POST /embeddings");
    expect(tracer.spans[1]._name).toBe("HTTP POST /chat/completions");
  });

  test("same middleware instance used twice creates two spans", async () => {
    const middleware = createOtelMiddleware({ endpoint: "/chat/completions" });
    await middleware(makeMiddlewareOptions())({});
    await middleware(makeMiddlewareOptions())({});
    expect(tracer.spans).toHaveLength(2);
    expect(tracer.spans[0].end).toHaveBeenCalledTimes(1);
    expect(tracer.spans[1].end).toHaveBeenCalledTimes(1);
  });
});
