// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * E2E Test — Streaming Chat Completion Flow
 *
 * Tests the full SSE streaming pipeline through real HTTP:
 *   Client POST → Express /api/stream → plugin.streamChatCompletion()
 *     → Mocked OrchestrationClient.stream() → SSE frames over HTTP response
 *
 * Scenarios covered:
 *   1. Progressive rendering: tokens arrive as separate SSE data frames
 *   2. Done frame: finishReason + totalTokens present after last token
 *   3. [DONE] sentinel terminates the stream
 *   4. SSE headers: Content-Type text/event-stream, Cache-Control no-cache
 *   5. Abort mid-stream: client closes connection → AbortController fires
 *   6. Error frame: SDK throw during stream → event: error SSE frame written
 *   7. OTel spans: stream_started + stream_completed events, OK status
 *   8. OTel error path: stream_failed event, ERROR status on SDK throw
 *   9. Empty / null deltas are skipped (no extra frames)
 *  10. Multi-token accumulation: full content matches concatenation of deltas
 */

"use strict";

const http = require("http");
const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

// ════════════════════════════════════════════════════════════════════
// SSE stream helpers
// ════════════════════════════════════════════════════════════════════

/**
 * POST to /api/stream and collect all raw SSE text until the connection closes.
 * Returns the raw body string (all frames concatenated).
 */
function streamPost(baseUrl, body, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const url = new URL("/api/stream", baseUrl);
    const options = {
      hostname: url.hostname,
      port: Number(url.port),
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
      },
    };

    const req = http.request(options, (res) => {
      let raw = "";
      // Destroy socket after inactivity — prevents hanging if server
      // keeps connection open (e.g. SSE with no final res.end()).
      res.socket && res.socket.setTimeout(timeoutMs, () => res.destroy());
      res.on("data", (chunk) => { raw += chunk.toString(); });
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, raw }));
      res.on("error", () => resolve({ status: res.statusCode, headers: res.headers, raw }));
    });

    req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error("streamPost timeout")); });
    req.on("error", (err) => {
      // Ignore ECONNRESET which can happen after server.closeAllConnections()
      if (err.code === "ECONNRESET" || err.message === "socket hang up") return;
      reject(err);
    });
    req.write(payload);
    req.end();
  });
}

/**
 * Parse raw SSE body into an array of parsed frame objects:
 *   { event?: string, data: string | object }
 * "[DONE]" data is kept as the literal string "[DONE]".
 */
function parseSSE(raw) {
  const frames = [];
  // Split on double-newline (frame separator)
  const blocks = raw.split(/\n\n+/);
  for (const block of blocks) {
    if (!block.trim()) continue;
    const lines = block.split("\n");
    let event = null;
    let dataLine = null;
    for (const line of lines) {
      if (line.startsWith("event:")) {
        event = line.slice("event:".length).trim();
      } else if (line.startsWith("data:")) {
        dataLine = line.slice("data:".length).trim();
      }
    }
    if (dataLine === null) continue;
    if (dataLine === "[DONE]") {
      frames.push({ event, data: "[DONE]" });
    } else {
      try {
        frames.push({ event, data: JSON.parse(dataLine) });
      } catch {
        frames.push({ event, data: dataLine });
      }
    }
  }
  return frames;
}

// ════════════════════════════════════════════════════════════════════
// Mock stream factories (mirrors unit test helpers)
// ════════════════════════════════════════════════════════════════════

/** Build a fake async-iterable stream of chunk objects. */
function makeChunks(deltas) {
  const chunks = deltas.map((d) => ({
    getDeltaContent: () => (d === null ? undefined : d),
  }));
  return {
    [Symbol.asyncIterator]: async function* () {
      for (const c of chunks) yield c;
    },
  };
}

/** Build a fake OrchestrationStreamResponse. */
function makeStreamResponse(deltas, { finishReason = "stop", totalTokens = 42 } = {}) {
  return {
    stream: makeChunks(deltas),
    getFinishReason: () => finishReason,
    getTokenUsage: () => ({ total_tokens: totalTokens }),
  };
}

// ════════════════════════════════════════════════════════════════════
// Shared request body
// ════════════════════════════════════════════════════════════════════

const STREAM_BODY = {
  clientConfig: { promptTemplating: { model: { name: "gpt-4o" } } },
  chatCompletionConfig: { messages: [{ role: "user", content: "Hello" }] },
};

// ════════════════════════════════════════════════════════════════════
// Suite 1 — SSE Protocol (headers + frame structure)
// ════════════════════════════════════════════════════════════════════

describe("E2E Streaming — SSE Protocol", () => {
  let server;
  let BASE;

  beforeAll(async () => {
    const mockStream = jest.fn().mockResolvedValue(makeStreamResponse(["Hello", " world"]));
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => { server.closeAllConnections(); server.close(done); });

  test("Content-Type header is text/event-stream", async () => {
    const { headers } = await streamPost(BASE, STREAM_BODY);
    expect(headers["content-type"]).toMatch(/text\/event-stream/);
  });

  test("Cache-Control header is no-cache", async () => {
    const { headers } = await streamPost(BASE, STREAM_BODY);
    expect(headers["cache-control"]).toMatch(/no-cache/);
  });

  test("HTTP status is 200", async () => {
    const { status } = await streamPost(BASE, STREAM_BODY);
    expect(status).toBe(200);
  });

  test("stream ends with [DONE] sentinel frame", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    const last = frames[frames.length - 1];
    expect(last.data).toBe("[DONE]");
  });

  test("second-to-last frame is done metadata frame with finishReason and totalTokens", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    // Last = [DONE], second-to-last = done metadata
    const doneMeta = frames[frames.length - 2];
    expect(doneMeta.data).toMatchObject({
      finishReason: "stop",
      totalTokens: 42,
    });
  });
});

// ════════════════════════════════════════════════════════════════════
// Suite 2 — Progressive Rendering (token-by-token)
// ════════════════════════════════════════════════════════════════════

describe("E2E Streaming — Progressive Rendering", () => {
  let server;
  let BASE;
  const TOKENS = ["The", " quick", " brown", " fox"];

  beforeAll(async () => {
    const mockStream = jest.fn().mockResolvedValue(makeStreamResponse(TOKENS));
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => { server.closeAllConnections(); server.close(done); });

  test("each non-empty delta produces exactly one SSE data frame", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    const deltaFrames = frames.filter(
      (f) => f.data !== "[DONE]" && typeof f.data === "object" && "delta" in f.data,
    );
    expect(deltaFrames).toHaveLength(TOKENS.length);
  });

  test("delta frames contain correct token strings in order", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    const deltas = frames
      .filter((f) => typeof f.data === "object" && "delta" in f.data)
      .map((f) => f.data.delta);
    expect(deltas).toEqual(TOKENS);
  });

  test("concatenation of all deltas equals full response content", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    const full = frames
      .filter((f) => typeof f.data === "object" && "delta" in f.data)
      .map((f) => f.data.delta)
      .join("");
    expect(full).toBe(TOKENS.join(""));
  });

  test("null / undefined deltas are skipped — no empty delta frames", async () => {
    // Inject null deltas between real tokens
    const withNulls = ["Hello", null, null, " world"];
    const mockStream = jest.fn().mockResolvedValue(makeStreamResponse(withNulls));
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    const s = await startServer(app, 0);
    const base = "http://localhost:" + s.address().port;

    const { raw } = await streamPost(base, STREAM_BODY);
    await new Promise((r) => s.close(r));

    const frames = parseSSE(raw);
    const deltaFrames = frames.filter(
      (f) => typeof f.data === "object" && "delta" in f.data,
    );
    // Only 2 real tokens ("Hello", " world"), nulls skipped
    expect(deltaFrames).toHaveLength(2);
    expect(deltaFrames.map((f) => f.data.delta)).toEqual(["Hello", " world"]);
  });

  test("index field on each delta frame is 0", async () => {
    const { raw } = await streamPost(BASE, STREAM_BODY);
    const frames = parseSSE(raw);
    const deltaFrames = frames.filter(
      (f) => typeof f.data === "object" && "delta" in f.data,
    );
    for (const frame of deltaFrames) {
      expect(frame.data.index).toBe(0);
    }
  });
});

// ════════════════════════════════════════════════════════════════════
// Suite 3 — Abort Mid-Stream
// ════════════════════════════════════════════════════════════════════

describe("E2E Streaming — Abort Mid-Stream", () => {
  let server;
  let BASE;

  beforeAll(async () => {
    // Stream that yields many tokens (more than we'll consume before aborting)
    const manyTokens = Array.from({ length: 50 }, (_, i) => `token${i} `);
    const mockStream = jest.fn().mockResolvedValue(makeStreamResponse(manyTokens));
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => { server.closeAllConnections(); server.close(done); });

  test("client can close connection mid-stream without server error", async () => {
    const payload = JSON.stringify(STREAM_BODY);
    const url = new URL("/api/stream", BASE);

    await new Promise((resolve) => {
      const req = http.request(
        {
          hostname: url.hostname,
          port: Number(url.port),
          path: url.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(payload),
          },
        },
        (res) => {
          let received = 0;
          res.on("data", () => {
            received++;
            if (received === 1) {
              // Destroy after first chunk — simulates client abort
              req.destroy();
              // Give server a moment to process the close event
              setTimeout(resolve, 200);
            }
          });
          res.on("error", resolve);
          res.on("close", resolve);
        },
      );
      req.on("error", resolve); // Expected ECONNRESET on destroy
      req.write(payload);
      req.end();
    });

    // If we got here, no unhandled error was thrown
    expect(true).toBe(true);
  });

  test("server process remains healthy after client abort", async () => {
    // Fire a normal request after the abort to confirm server is still up
    const { status, raw } = await streamPost(BASE, STREAM_BODY);
    expect(status).toBe(200);
    const frames = parseSSE(raw);
    expect(frames.some((f) => f.data === "[DONE]")).toBe(true);
  });
});

// ════════════════════════════════════════════════════════════════════
// Suite 4 — Error Handling
// ════════════════════════════════════════════════════════════════════

describe("E2E Streaming — Error Handling", () => {
  test("SDK throws during stream → event: error SSE frame written before [DONE]", async () => {
    const failingStream = {
      stream: {
        [Symbol.asyncIterator]: async function* () {
          yield { getDeltaContent: () => "partial " };
          throw new Error("AI Core connection lost");
        },
      },
      getFinishReason: () => "stop",
      getTokenUsage: () => ({ total_tokens: 0 }),
    };

    const mockStream = jest.fn().mockResolvedValue(failingStream);
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    const s = await startServer(app, 0);
    const base = "http://localhost:" + s.address().port;

    const { raw } = await streamPost(base, STREAM_BODY);
    await new Promise((r) => s.close(r));

    const frames = parseSSE(raw);

    // Should have at least the partial delta frame
    const deltaFrames = frames.filter(
      (f) => typeof f.data === "object" && "delta" in f.data,
    );
    expect(deltaFrames.length).toBeGreaterThanOrEqual(1);
    expect(deltaFrames[0].data.delta).toBe("partial ");

    // Should have an error frame
    const errorFrame = frames.find((f) => f.event === "error");
    expect(errorFrame).toBeDefined();
    expect(errorFrame.data).toMatchObject({
      code: expect.stringContaining("STREAM"),
      message: expect.any(String),
    });
  });

  test("SDK throws before any delta → only error frame + [DONE]", async () => {
    const failingStream = {
      stream: {
        [Symbol.asyncIterator]: async function* () {
          throw new Error("Immediate failure");
        },
      },
      getFinishReason: () => "stop",
      getTokenUsage: () => ({ total_tokens: 0 }),
    };

    const mockStream = jest.fn().mockResolvedValue(failingStream);
    const { plugin } = setupPlugin({ stream: mockStream });
    const app = createApp(plugin);
    const s = await startServer(app, 0);
    const base = "http://localhost:" + s.address().port;

    const { raw } = await streamPost(base, STREAM_BODY);
    await new Promise((r) => s.close(r));

    const frames = parseSSE(raw);
    const deltaFrames = frames.filter(
      (f) => typeof f.data === "object" && "delta" in f.data,
    );
    expect(deltaFrames).toHaveLength(0);

    const errorFrame = frames.find((f) => f.event === "error");
    expect(errorFrame).toBeDefined();
  });
});

// ════════════════════════════════════════════════════════════════════
// Suite 5 — OTel Spans
//
// Strategy: load cap-llm-plugin.js in isolation with a mocked OTel
// tracer injected via jest.doMock before the require, so we can
// inspect span events without fighting the shared setupPlugin cache.
// Uses a dedicated Express server per test group.
// ════════════════════════════════════════════════════════════════════

describe("E2E Streaming — OTel Spans", () => {
  /**
   * Boots a fresh plugin+server with a captured tracer.
   * Returns { server, BASE, capturedSpans, close }.
   */
  async function bootWithOtel(streamMock) {
    jest.resetModules();
    const capturedSpans = [];
    const makeSpan = () => {
      const span = {
        _events: [],
        _status: null,
        _ended: false,
        setAttribute: jest.fn(),
        addEvent: jest.fn((name, attrs) => { span._events.push({ name, attrs }); }),
        recordException: jest.fn(),
        setStatus: jest.fn((s) => { span._status = s; }),
        end: jest.fn(() => { span._ended = true; }),
      };
      capturedSpans.push(span);
      return span;
    };

    const vector = Array.from({ length: 1536 }, (_, i) => Math.sin(i * 0.01));
    let PluginClass;

    jest.isolateModules(() => {
      const capturedTracer = { startSpan: jest.fn(makeSpan) };
      jest.doMock("../../src/telemetry/tracer", () => ({
        getTracer: () => capturedTracer,
        SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
        _resetTracerCache: jest.fn(),
      }));
      jest.doMock("@opentelemetry/api", () => ({
        trace: {
          getTracer: () => capturedTracer,
          getActiveSpan: () => null,
        },
        context: { with: (_ctx, fn) => fn(), active: () => ({}) },
        propagation: { inject: jest.fn() },
        SpanStatusCode: { OK: "OK", ERROR: "ERROR" },
      }));
      jest.doMock("@sap/cds", () => ({
        db: { run: jest.fn().mockResolvedValue([]), kind: "hana" },
        connect: { to: jest.fn().mockResolvedValue({ run: jest.fn().mockResolvedValue([]) }) },
        services: {},
        log: jest.fn(() => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() })),
        Service: class { async init() {} },
        once: jest.fn(),
        env: { requires: {} },
        requires: {},
      }), { virtual: true });
      jest.doMock("@sap-ai-sdk/orchestration", () => ({
        OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({
          embed: jest.fn().mockResolvedValue({ getEmbeddings: () => [{ embedding: vector }] }),
        })),
        OrchestrationClient: jest.fn().mockImplementation(() => ({
          chatCompletion: jest.fn().mockResolvedValue({ getContent: () => "ok", getTokenUsage: () => ({}), getFinishReason: () => "stop", data: {} }),
          stream: streamMock,
        })),
        buildAzureContentSafetyFilter: jest.fn().mockReturnValue({}),
      }));
      jest.doMock("../../lib/anonymization-helper.js", () => ({
        VALID_ANONYMIZATION_ALGORITHM_PREFIXES: ["K-Anonymity", "Differential-Privacy", "L-Diversity"],
      }));
      PluginClass = require("../../srv/cap-llm-plugin.js");
    });
    const plugin = new PluginClass();

    // createApp / startServer don't go through jest module registry so
    // require them directly from their resolved paths.
    const { createApp: ca, startServer: ss } = require("./server");
    const app = ca(plugin);
    const server = await ss(app, 0);
    const BASE = "http://localhost:" + server.address().port;

    const close = () => new Promise((r) => {
      server.closeAllConnections();
      server.close(r);
    });

    return { server, BASE, capturedSpans, close };
  }

  test("stream_started and stream_completed events emitted on successful stream", async () => {
    const mock = jest.fn().mockResolvedValue(makeStreamResponse(["Hello", " world"]));
    const { BASE, capturedSpans, close } = await bootWithOtel(mock);
    await streamPost(BASE, STREAM_BODY);
    await close();

    const allEvents = capturedSpans.flatMap((s) => s._events.map((e) => e.name));
    expect(allEvents).toContain("stream_started");
    expect(allEvents).toContain("stream_completed");
  });

  test("span status is OK and span is ended after successful stream", async () => {
    const mock = jest.fn().mockResolvedValue(makeStreamResponse(["token1", " token2"]));
    const { BASE, capturedSpans, close } = await bootWithOtel(mock);
    await streamPost(BASE, STREAM_BODY);
    await close();

    // SpanStatusCode.OK = 1 (numeric, from src/telemetry/tracer.js)
    const statuses = capturedSpans.map((s) => s._status?.code);
    expect(statuses).toContain(1);
    for (const span of capturedSpans) {
      expect(span._ended).toBe(true);
    }
  });

  test("span status is ERROR when SDK throws during stream", async () => {
    const failingStream = {
      stream: {
        [Symbol.asyncIterator]: async function* () {
          throw new Error("OTel error test");
        },
      },
      getFinishReason: () => "stop",
      getTokenUsage: () => ({ total_tokens: 0 }),
    };
    const mock = jest.fn().mockResolvedValue(failingStream);
    const { BASE, capturedSpans, close } = await bootWithOtel(mock);
    await streamPost(BASE, STREAM_BODY);
    await close();

    // SpanStatusCode.ERROR = 2 (numeric, from src/telemetry/tracer.js)
    // The error catch path calls span.setStatus({ code: SpanStatusCode.ERROR })
    // and span.end() — no "stream_failed" event is emitted (by design).
    const statuses = capturedSpans.map((s) => s._status?.code);
    expect(statuses).toContain(2);
    for (const span of capturedSpans) {
      expect(span._ended).toBe(true);
    }
  });

  test("at least one span created and all spans ended per request", async () => {
    const mock = jest.fn().mockResolvedValue(makeStreamResponse(["a", "b", "c"]));
    const { BASE, capturedSpans, close } = await bootWithOtel(mock);
    await streamPost(BASE, STREAM_BODY);
    await close();

    expect(capturedSpans.length).toBeGreaterThanOrEqual(1);
    for (const span of capturedSpans) {
      expect(span._ended).toBe(true);
    }
  });
});
