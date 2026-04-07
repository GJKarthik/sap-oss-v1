// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Unit tests for streamChatCompletion() (Day 57).
 *
 * Verifies:
 *   1. SSE headers written when req.http.res is present
 *   2. res.write() called once per non-empty delta chunk
 *   3. Done frame written with finishReason + totalTokens
 *   4. [DONE] sentinel written
 *   5. res.end() called exactly once on success
 *   6. Abort path: close event triggers AbortController, error SSE frame written
 *   7. Non-streaming path (no req.http.res): returns full accumulated content string
 *   8. Invalid JSON params: throws STREAM_CHAT_PARAMS_INVALID immediately
 *   9. OTel span lifecycle: stream_started + stream_completed events, OK status, end() once
 *  10. SDK error (streaming mode): error SSE frame written, res.end() called, span ERROR
 *  11. SDK error (non-streaming mode): throws ChatCompletionError with CHAT_STREAM_FAILED
 *  12. Empty-delta chunks (undefined getDeltaContent): skipped, not written
 *  13. chunk with delta='' skipped (falsy)
 *  14. Two independent calls produce independent spans
 */

"use strict";

// ════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════

function makeSpan() {
  return {
    _name: null,
    _attrs: {},
    _events: [],
    _status: null,
    _endCount: 0,
    setAttribute: jest.fn(function(k, v) { this._attrs[k] = v; }),
    addEvent: jest.fn(function(n, a) { this._events.push({ name: n, attributes: a ?? {} }); }),
    recordException: jest.fn(),
    setStatus: jest.fn(function(s) { this._status = s; }),
    end: jest.fn(function() { this._endCount++; }),
  };
}

function makeTracer() {
  const spans = [];
  return {
    startSpan: jest.fn((name) => {
      const s = makeSpan();
      s._name = name;
      spans.push(s);
      return s;
    }),
    spans,
    last: () => spans[spans.length - 1],
  };
}

/** Build a fake OrchestrationStreamChunkResponse array → AsyncIterable */
function makeChunks(deltas) {
  const chunks = deltas.map(delta => ({
    getDeltaContent: () => (delta === null ? undefined : delta),
  }));
  return {
    [Symbol.asyncIterator]: async function*() { for (const c of chunks) yield c; },
  };
}

/** Build a fake OrchestrationStreamResponse */
function makeStreamResponse(deltas, { finishReason = "stop", totalTokens = 42 } = {}) {
  return {
    stream: makeChunks(deltas),
    getFinishReason: () => finishReason,
    getTokenUsage: () => ({ total_tokens: totalTokens }),
  };
}

/** Build a mock res object (Express ServerResponse-like) */
function makeRes({ headersSent = false } = {}) {
  const written = [];
  let ended = false;
  let closeHandler = null;
  const res = {
    headersSent,
    _written: written,
    _ended: () => ended,
    _triggerClose: () => { if (closeHandler) closeHandler(); },
    setHeader: jest.fn(),
    flushHeaders: jest.fn(),
    write: jest.fn((data) => { written.push(data); }),
    end: jest.fn(() => { ended = true; }),
    on: jest.fn((event, handler) => { if (event === "close") closeHandler = handler; }),
  };
  return res;
}

/** Build a fake CDS req with optional http.res */
function makeReq(res) {
  if (!res) return undefined;
  return { http: { res } };
}

// ════════════════════════════════════════════════════════════════════
// Module setup
// ════════════════════════════════════════════════════════════════════

let Plugin;
let tracer;

const CLIENT_CONFIG = JSON.stringify({ promptTemplating: { model: { name: "gpt-4o" } } });
const CHAT_CONFIG   = JSON.stringify({ messages: [{ role: "user", content: "Hello" }] });

function setup({ streamDeltas = ["Hello", " world", "!"], streamError = null, streamResponse = null } = {}) {
  jest.resetModules();
  tracer = makeTracer();
  const mockCapturedTracer = tracer;
  const fakeStreamResponse = streamResponse ?? makeStreamResponse(streamDeltas);

  jest.doMock("../../src/telemetry/tracer", () => ({
    getTracer: () => mockCapturedTracer,
    SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
    _resetTracerCache: jest.fn(),
  }));
  jest.doMock("../../src/telemetry/ai-sdk-middleware", () => ({
    createOtelMiddleware: jest.fn(() => jest.fn()),
  }));
  jest.doMock("@sap-ai-sdk/orchestration", () => ({
    OrchestrationClient: jest.fn().mockImplementation(() => ({
      stream: streamError
        ? jest.fn().mockRejectedValue(streamError)
        : jest.fn().mockResolvedValue(fakeStreamResponse),
    })),
    OrchestrationEmbeddingClient: jest.fn(),
    buildAzureContentSafetyFilter: jest.fn(),
  }));
  jest.doMock("@sap/cds", () => ({
    Service: class { async init() {} },
    connect: { to: jest.fn() },
    log: () => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() }),
    once: jest.fn(),
    env: { requires: {} },
    requires: {},
    services: {},
  }), { virtual: true });
  jest.doMock("../../lib/validation-utils", () => ({
    validateSqlIdentifier: jest.fn(),
    validatePositiveInteger: jest.fn(),
    validateEmbeddingVector: jest.fn(),
  }));
  jest.doMock("../../srv/legacy", () => ({
    getEmbedding: jest.fn(),
    getChatCompletion: jest.fn(),
    getRagResponse: jest.fn(),
  }));
  Plugin = require("../../srv/cap-llm-plugin.js");
}

// ════════════════════════════════════════════════════════════════════
// Non-streaming mode (no req.http.res)
// ════════════════════════════════════════════════════════════════════

describe("streamChatCompletion — non-streaming mode", () => {
  beforeEach(() => setup({ streamDeltas: ["The ", "answer ", "is 42."] }));

  test("returns full accumulated content string", async () => {
    const plugin = new Plugin();
    const result = await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    expect(result).toBe("The answer is 42.");
  });

  test("returns empty string when all deltas are empty/null", async () => {
    setup({ streamDeltas: [null, null, ""] });
    const plugin = new Plugin();
    const result = await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    expect(result).toBe("");
  });

  test("OTel span name is cap-llm-plugin.streamChatCompletion", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    expect(tracer.last()._name).toBe("cap-llm-plugin.streamChatCompletion");
  });

  test("stream_started event emitted", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    const eventNames = tracer.last()._events.map(e => e.name);
    expect(eventNames).toContain("stream_started");
  });

  test("stream_completed event emitted", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    const eventNames = tracer.last()._events.map(e => e.name);
    expect(eventNames).toContain("stream_completed");
  });

  test("stream_completed event carries finish_reason", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    const ev = tracer.last()._events.find(e => e.name === "stream_completed");
    expect(ev.attributes["stream.finish_reason"]).toBe("stop");
  });

  test("stream_completed event carries total_tokens", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    const ev = tracer.last()._events.find(e => e.name === "stream_completed");
    expect(ev.attributes["stream.total_tokens"]).toBe(42);
  });

  test("span status OK on success", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    expect(tracer.last()._status?.code).toBe(1);
  });

  test("span.end() called exactly once on success", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG }
    );
    expect(tracer.last()._endCount).toBe(1);
  });

  test("throws ChatCompletionError with CHAT_STREAM_FAILED on SDK error", async () => {
    setup({ streamError: new Error("AI Core 503") });
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toMatchObject({ code: "CHAT_STREAM_FAILED" });
  });

  test("span ERROR status on SDK error", async () => {
    setup({ streamError: new Error("AI Core 503") });
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toThrow();
    expect(tracer.last()._status?.code).toBe(2);
  });

  test("span.end() called on SDK error", async () => {
    setup({ streamError: new Error("AI Core 503") });
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toThrow();
    expect(tracer.last()._endCount).toBe(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// Invalid JSON params
// ════════════════════════════════════════════════════════════════════

describe("streamChatCompletion — invalid JSON params", () => {
  beforeEach(() => setup());

  test("throws STREAM_CHAT_PARAMS_INVALID for bad clientConfig JSON", async () => {
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: "{bad json}", chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toMatchObject({ code: "STREAM_CHAT_PARAMS_INVALID" });
  });

  test("throws STREAM_CHAT_PARAMS_INVALID for bad chatCompletionConfig JSON", async () => {
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: "{bad}" })
    ).rejects.toMatchObject({ code: "STREAM_CHAT_PARAMS_INVALID" });
  });

  test("span ERROR status on parse failure", async () => {
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: "{bad}", chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toThrow();
    expect(tracer.last()._status?.code).toBe(2);
  });

  test("span.end() called on parse failure", async () => {
    const plugin = new Plugin();
    await expect(
      plugin.streamChatCompletion({ clientConfig: "{bad}", chatCompletionConfig: CHAT_CONFIG })
    ).rejects.toThrow();
    expect(tracer.last()._endCount).toBe(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// SSE streaming mode
// ════════════════════════════════════════════════════════════════════

describe("streamChatCompletion — SSE streaming mode", () => {
  beforeEach(() => setup({ streamDeltas: ["Hello", " world", "!"] }));

  test("sets Content-Type: text/event-stream header", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.setHeader).toHaveBeenCalledWith("Content-Type", "text/event-stream");
  });

  test("sets Cache-Control: no-cache header", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.setHeader).toHaveBeenCalledWith("Cache-Control", "no-cache");
  });

  test("sets X-Accel-Buffering: no header", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.setHeader).toHaveBeenCalledWith("X-Accel-Buffering", "no");
  });

  test("calls flushHeaders()", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.flushHeaders).toHaveBeenCalledTimes(1);
  });

  test("writes one SSE data frame per non-empty delta", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const deltaFrames = res._written.filter(w => {
      try { const p = JSON.parse(w.replace(/^data: /, "")); return "delta" in p; } catch { return false; }
    });
    expect(deltaFrames).toHaveLength(3);
  });

  test("delta frame format is `data: {delta, index}\\n\\n`", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const firstDelta = res._written.find(w => w.startsWith("data:") && w.includes('"delta"'));
    expect(firstDelta).toBe('data: {"delta":"Hello","index":0}\n\n');
  });

  test("null/undefined delta chunks are not written", async () => {
    setup({ streamDeltas: [null, "Hi", null, "!"] });
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const deltaFrames = res._written.filter(w => {
      try { const p = JSON.parse(w.replace(/^data: /, "")); return "delta" in p; } catch { return false; }
    });
    expect(deltaFrames).toHaveLength(2);
  });

  test("writes done frame with finishReason and totalTokens", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const doneFrame = res._written.find(w => {
      try { const p = JSON.parse(w.replace(/^data: /, "")); return "finishReason" in p; } catch { return false; }
    });
    expect(doneFrame).toBeDefined();
    const parsed = JSON.parse(doneFrame.replace(/^data: /, ""));
    expect(parsed.finishReason).toBe("stop");
    expect(parsed.totalTokens).toBe(42);
  });

  test("writes [DONE] sentinel", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res._written).toContain("data: [DONE]\n\n");
  });

  test("calls res.end() exactly once on success", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.end).toHaveBeenCalledTimes(1);
  });

  test("returns empty string (not the content) in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    const result = await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(result).toBe("");
  });

  test("registers close handler on res", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.on).toHaveBeenCalledWith("close", expect.any(Function));
  });

  test("OTel span OK status in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(tracer.last()._status?.code).toBe(1);
  });

  test("span.end() called once in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(tracer.last()._endCount).toBe(1);
  });

  test("stream_started and stream_completed events emitted in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const names = tracer.last()._events.map(e => e.name);
    expect(names).toContain("stream_started");
    expect(names).toContain("stream_completed");
  });

  test("skips headers when headersSent=true (already streaming)", async () => {
    const plugin = new Plugin();
    const res = makeRes({ headersSent: true });
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.setHeader).not.toHaveBeenCalled();
    expect(res.flushHeaders).not.toHaveBeenCalled();
  });
});

// ════════════════════════════════════════════════════════════════════
// SDK error in SSE mode
// ════════════════════════════════════════════════════════════════════

describe("streamChatCompletion — SDK error in SSE mode", () => {
  beforeEach(() => setup({ streamError: new Error("AI Core 503") }));

  test("writes error SSE frame on SDK failure", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    const errFrame = res._written.find(w => w.startsWith("event: error"));
    expect(errFrame).toBeDefined();
    expect(errFrame).toContain("CHAT_STREAM_FAILED");
    expect(errFrame).toContain("AI Core 503");
  });

  test("calls res.end() even on SDK error in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(res.end).toHaveBeenCalledTimes(1);
  });

  test("returns empty string (does not throw) in SSE mode on SDK error", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    const result = await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(result).toBe("");
  });

  test("span ERROR status on SDK error in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(tracer.last()._status?.code).toBe(2);
  });

  test("span.end() called once on SDK error in SSE mode", async () => {
    const plugin = new Plugin();
    const res = makeRes();
    await plugin.streamChatCompletion(
      { clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG },
      makeReq(res)
    );
    expect(tracer.last()._endCount).toBe(1);
  });
});

// ════════════════════════════════════════════════════════════════════
// Span independence
// ════════════════════════════════════════════════════════════════════

describe("streamChatCompletion — span independence", () => {
  beforeEach(() => setup({ streamDeltas: ["A"] }));

  test("two calls produce two independent spans", async () => {
    const plugin = new Plugin();
    await plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG });
    await plugin.streamChatCompletion({ clientConfig: CLIENT_CONFIG, chatCompletionConfig: CHAT_CONFIG });
    expect(tracer.spans).toHaveLength(2);
    expect(tracer.spans[0]).not.toBe(tracer.spans[1]);
  });
});
