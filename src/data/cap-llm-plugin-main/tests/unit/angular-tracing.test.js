// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Unit tests for Angular OTel tracing (Day 54).
 *
 * Tests the framework-agnostic core in src/telemetry/angular-tracing.ts
 * (compiled to src/telemetry/angular-tracing.js by tsc) — zero Angular deps.
 *
 * Covers:
 *   - injectTraceContextHeaders()  W3C header injection
 *   - withSpan()                   span lifecycle
 *   - withChatSpan()               span name + llm.interaction attribute
 *   - withRagSpan()                span name + llm.interaction attribute
 *   - withFilterSpan()             span name + llm.interaction attribute
 *   - addEventToActiveSpan()       addEvent on the active span
 *   - TracingSpanStatus            constants
 *
 * @opentelemetry/api is controlled per test group via jest.doMock().
 */

"use strict";

// ════════════════════════════════════════════════════════════════════
// Spy tracer helpers
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
// Module loader helpers
// ════════════════════════════════════════════════════════════════════

let injectTraceContextHeaders;
let withSpan;
let withChatSpan;
let withRagSpan;
let withFilterSpan;
let addEventToActiveSpan;
let TracingSpanStatus;

// src/telemetry/angular-tracing.js is compiled from angular-tracing.ts
// (standard tsc pipeline, no Angular dependencies).

function loadModules({
  otelAvailable = false,
  activeSpan = null,
  customTracer = null,
  injectImpl = null,
} = {}) {
  jest.resetModules();
  const mockLoadedTracer = customTracer ?? makeTracer();
  const mockActiveSpan = activeSpan;

  if (otelAvailable) {
    const mockInject = injectImpl ?? jest.fn((ctx, carrier) => {
      carrier["traceparent"] = "00-abc123def456-aabbccdd-01";
      carrier["tracestate"] = "vendor=value";
    });
    jest.doMock("@opentelemetry/api", () => ({
      propagation: { inject: mockInject },
      context: { active: jest.fn().mockReturnValue({}) },
      trace: {
        getTracer: jest.fn().mockReturnValue(mockLoadedTracer),
        getActiveSpan: jest.fn().mockReturnValue(mockActiveSpan),
        getSpan: jest.fn().mockReturnValue(mockActiveSpan),
      },
      _mockInject: mockInject,
    }));
  } else {
    jest.doMock("@opentelemetry/api", () => {
      throw Object.assign(new Error("Cannot find module '@opentelemetry/api'"), {
        code: "MODULE_NOT_FOUND",
      });
    });
  }
  jest.doMock("../../src/telemetry/tracer", () => ({
    getTracer: () => mockLoadedTracer,
    SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
  }));
  ({
    injectTraceContextHeaders,
    withSpan,
    withChatSpan,
    withRagSpan,
    withFilterSpan,
    addEventToActiveSpan,
    TracingSpanStatus,
  } = require("../../src/telemetry/angular-tracing"));
}

// ════════════════════════════════════════════════════════════════════
// TracingSpanStatus constants
// ════════════════════════════════════════════════════════════════════

describe("TracingSpanStatus constants", () => {
  beforeEach(() => loadModules());

  test("UNSET = 0", () => expect(TracingSpanStatus.UNSET).toBe(0));
  test("OK = 1",    () => expect(TracingSpanStatus.OK).toBe(1));
  test("ERROR = 2", () => expect(TracingSpanStatus.ERROR).toBe(2));
});

// ════════════════════════════════════════════════════════════════════
// injectTraceContextHeaders — when OTel NOT available
// ════════════════════════════════════════════════════════════════════

describe("injectTraceContextHeaders — OTel not available", () => {
  beforeEach(() => loadModules({ otelAvailable: false }));

  test("returns the original headers object unchanged", () => {
    const headers = { "content-type": "application/json" };
    const result = injectTraceContextHeaders(headers);
    expect(result).toBe(headers);
  });

  test("does not add traceparent key", () => {
    const result = injectTraceContextHeaders({});
    expect(result["traceparent"]).toBeUndefined();
  });

  test("does not throw", () => {
    expect(() => injectTraceContextHeaders({})).not.toThrow();
  });

  test("works with no argument (default empty headers)", () => {
    expect(() => injectTraceContextHeaders()).not.toThrow();
  });
});

// ════════════════════════════════════════════════════════════════════
// injectTraceContextHeaders — when OTel IS available
// ════════════════════════════════════════════════════════════════════

describe("injectTraceContextHeaders — OTel available", () => {
  beforeEach(() => loadModules({ otelAvailable: true }));

  test("returns a new object (not the original) when headers injected", () => {
    const headers = {};
    const result = injectTraceContextHeaders(headers);
    expect(result).not.toBe(headers);
  });

  test("returned object has traceparent set", () => {
    const result = injectTraceContextHeaders({});
    expect(result["traceparent"]).toBe("00-abc123def456-aabbccdd-01");
  });

  test("returned object has tracestate set", () => {
    const result = injectTraceContextHeaders({});
    expect(result["tracestate"]).toBe("vendor=value");
  });

  test("preserves existing headers in the returned object", () => {
    const result = injectTraceContextHeaders({ "x-custom": "my-value" });
    expect(result["x-custom"]).toBe("my-value");
    expect(result["traceparent"]).toBeDefined();
  });

  test("calls propagation.inject with an active context carrier", () => {
    const { _mockInject } = require("@opentelemetry/api");
    injectTraceContextHeaders({});
    expect(_mockInject).toHaveBeenCalledWith(
      expect.anything(),
      expect.any(Object),
    );
  });

  test("returns original headers object when inject produces nothing", () => {
    loadModules({ otelAvailable: true, injectImpl: jest.fn() });
    const headers = { "content-type": "application/json" };
    const result = injectTraceContextHeaders(headers);
    expect(result).toBe(headers);
  });
});

// ════════════════════════════════════════════════════════════════════
// withSpan — no-op tracer (OTel absent)
// ════════════════════════════════════════════════════════════════════

describe("withSpan — OTel not available (no-op tracer)", () => {
  beforeEach(() => loadModules({ otelAvailable: false }));

  test("executes the callback and returns its value", async () => {
    const result = await withSpan("test.span", async () => 42);
    expect(result).toBe(42);
  });

  test("resolves without throwing", async () => {
    await expect(withSpan("test", async () => "ok")).resolves.toBe("ok");
  });

  test("re-throws errors from the callback", async () => {
    await expect(
      withSpan("test", async () => { throw new Error("cb error"); })
    ).rejects.toThrow("cb error");
  });
});

// ════════════════════════════════════════════════════════════════════
// withSpan — with spy tracer
// ════════════════════════════════════════════════════════════════════

describe("withSpan — spy tracer", () => {
  let spyTracer;

  beforeEach(() => {
    spyTracer = makeTracer();
    loadModules({ customTracer: spyTracer });
  });

  test("starts a span with the given name", async () => {
    await withSpan("my.operation", async () => {});
    expect(spyTracer.startSpan).toHaveBeenCalledWith("my.operation");
  });

  test("calls span.end() exactly once on success", async () => {
    await withSpan("test", async () => {});
    expect(spyTracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("sets OK status on success", async () => {
    await withSpan("test", async () => {});
    expect(spyTracer.lastSpan().setStatus).toHaveBeenCalledWith({ code: 1 });
  });

  test("records exception on error", async () => {
    const err = new Error("something broke");
    await expect(withSpan("test", async () => { throw err; })).rejects.toThrow();
    expect(spyTracer.lastSpan().recordException).toHaveBeenCalledWith(err);
  });

  test("sets ERROR status on error", async () => {
    await expect(
      withSpan("test", async () => { throw new Error("fail"); })
    ).rejects.toThrow();
    expect(spyTracer.lastSpan().setStatus).toHaveBeenCalledWith(
      expect.objectContaining({ code: 2 })
    );
  });

  test("calls span.end() exactly once on error", async () => {
    await expect(
      withSpan("test", async () => { throw new Error("fail"); })
    ).rejects.toThrow();
    expect(spyTracer.lastSpan().end).toHaveBeenCalledTimes(1);
  });

  test("passes span to the callback", async () => {
    let capturedSpan;
    await withSpan("test", async (span) => { capturedSpan = span; });
    expect(capturedSpan).toBeDefined();
    expect(typeof capturedSpan.setAttribute).toBe("function");
  });

  test("returns value from callback", async () => {
    const result = await withSpan("test", async () => "hello");
    expect(result).toBe("hello");
  });

  test("two calls create independent spans", async () => {
    await withSpan("op.one", async () => {});
    await withSpan("op.two", async () => {});
    expect(spyTracer.spans).toHaveLength(2);
    expect(spyTracer.spans[0].end).toHaveBeenCalledTimes(1);
    expect(spyTracer.spans[1].end).toHaveBeenCalledTimes(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// withChatSpan, withRagSpan, withFilterSpan
// ════════════════════════════════════════════════════════════════════

describe("semantic span helpers — spy tracer", () => {
  let spyTracer;

  beforeEach(() => {
    spyTracer = makeTracer();
    loadModules({ customTracer: spyTracer });
  });

  // ── withChatSpan ──────────────────────────────────────────────────

  test("withChatSpan uses span name chat.<label>", async () => {
    await withChatSpan("send_message", async () => {});
    expect(spyTracer.startSpan).toHaveBeenCalledWith("chat.send_message");
  });

  test("withChatSpan sets llm.interaction = chat", async () => {
    await withChatSpan("send_message", async () => {});
    expect(spyTracer.lastSpan().setAttribute).toHaveBeenCalledWith("llm.interaction", "chat");
  });

  test("withChatSpan calls the callback and returns value", async () => {
    const cb = jest.fn().mockResolvedValue("chat result");
    expect(await withChatSpan("test", cb)).toBe("chat result");
    expect(cb).toHaveBeenCalledTimes(1);
  });

  // ── withRagSpan ───────────────────────────────────────────────────

  test("withRagSpan uses span name rag.<label>", async () => {
    await withRagSpan("query", async () => {});
    expect(spyTracer.startSpan).toHaveBeenCalledWith("rag.query");
  });

  test("withRagSpan sets llm.interaction = rag", async () => {
    await withRagSpan("query", async () => {});
    expect(spyTracer.lastSpan().setAttribute).toHaveBeenCalledWith("llm.interaction", "rag");
  });

  test("withRagSpan calls the callback and returns value", async () => {
    expect(await withRagSpan("test", async () => "rag result")).toBe("rag result");
  });

  // ── withFilterSpan ────────────────────────────────────────────────

  test("withFilterSpan uses span name filter.<label>", async () => {
    await withFilterSpan("change", async () => {});
    expect(spyTracer.startSpan).toHaveBeenCalledWith("filter.change");
  });

  test("withFilterSpan sets llm.interaction = filter", async () => {
    await withFilterSpan("change", async () => {});
    expect(spyTracer.lastSpan().setAttribute).toHaveBeenCalledWith("llm.interaction", "filter");
  });

  test("withFilterSpan calls the callback and returns value", async () => {
    expect(await withFilterSpan("test", async () => "filter result")).toBe("filter result");
  });
});

// ════════════════════════════════════════════════════════════════════
// addEventToActiveSpan
// ════════════════════════════════════════════════════════════════════

describe("addEventToActiveSpan — with active span", () => {
  let mockActiveSpan;

  beforeEach(() => {
    mockActiveSpan = makeSpan();
    loadModules({ otelAvailable: true, activeSpan: mockActiveSpan });
  });

  test("calls addEvent on the active span", () => {
    addEventToActiveSpan("user.input_submitted");
    expect(mockActiveSpan.addEvent).toHaveBeenCalledWith(
      "user.input_submitted", undefined
    );
  });

  test("passes attributes to the active span", () => {
    addEventToActiveSpan("user.input_submitted", { "input.length": 42 });
    expect(mockActiveSpan.addEvent).toHaveBeenCalledWith(
      "user.input_submitted", { "input.length": 42 }
    );
  });
});

describe("addEventToActiveSpan — no active span", () => {
  test("does not throw when no active span", () => {
    loadModules({ otelAvailable: true, activeSpan: null });
    expect(() => addEventToActiveSpan("something")).not.toThrow();
  });

  test("does not throw when OTel absent", () => {
    loadModules({ otelAvailable: false });
    expect(() => addEventToActiveSpan("something")).not.toThrow();
  });
});
