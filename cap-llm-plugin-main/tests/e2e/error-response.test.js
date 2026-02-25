/**
 * E2E Test — Standardized Error Response Format (Day 47)
 *
 * Verifies that all plugin endpoints return the canonical LLMErrorResponse
 * shape with correct HTTP status codes when errors occur.
 *
 * All error responses must conform to:
 *   { "error": { "code": string, "message": string, "details"?: object } }
 *
 * HTTP status codes:
 *   400 — config validation errors (EMBEDDING_CONFIG_INVALID, CHAT_CONFIG_INVALID, etc.)
 *   404 — not found (ENTITY_NOT_FOUND, SEQUENCE_COLUMN_NOT_FOUND)
 *   500 — upstream/SDK failures
 */

const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

let BASE;

describe("E2E Error Response Format", () => {
  let server;

  beforeAll(async () => {
    const { plugin } = setupPlugin();
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => server.close(done));

  async function post(path, body) {
    const res = await fetch(BASE + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    return { status: res.status, data };
  }

  // ── LLMErrorResponse shape contract ────────────────────────────────

  function assertLLMErrorShape(data) {
    expect(data).toHaveProperty("error");
    expect(data.error).toHaveProperty("code");
    expect(data.error).toHaveProperty("message");
    expect(typeof data.error.code).toBe("string");
    expect(typeof data.error.message).toBe("string");
    expect(data.error.code.length).toBeGreaterThan(0);
    expect(data.error.message.length).toBeGreaterThan(0);
  }

  // ── /api/embedding — config validation → 400 ───────────────────────

  test("embedding: missing modelName → 400 EMBEDDING_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/embedding", {
      config: { resourceGroup: "default" },
      input: "test",
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(data.error.details).toMatchObject({ missingField: "modelName" });
  });

  test("embedding: missing resourceGroup → 400 EMBEDDING_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/embedding", {
      config: { modelName: "text-embedding-ada-002" },
      input: "test",
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(data.error.details).toMatchObject({ missingField: "resourceGroup" });
  });

  test("embedding: null config → 400 EMBEDDING_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/embedding", {
      config: null,
      input: "test",
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("EMBEDDING_CONFIG_INVALID");
  });

  // ── /api/chat — config validation → 400 ────────────────────────────

  test("chat: missing modelName → 400 CHAT_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/chat", {
      config: { resourceGroup: "default" },
      payload: { messages: [{ role: "user", content: "Hi" }] },
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("CHAT_CONFIG_INVALID");
    expect(data.error.details).toMatchObject({ missingField: "modelName" });
  });

  test("chat: missing resourceGroup → 400 CHAT_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/chat", {
      config: { modelName: "gpt-4o" },
      payload: { messages: [{ role: "user", content: "Hi" }] },
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("CHAT_CONFIG_INVALID");
    expect(data.error.details).toMatchObject({ missingField: "resourceGroup" });
  });

  test("chat: null config → 400 CHAT_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/chat", {
      config: null,
      payload: { messages: [{ role: "user", content: "Hi" }] },
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("CHAT_CONFIG_INVALID");
  });

  // ── /api/filters — unsupported type → 400 ──────────────────────────

  test("filters: unsupported type → 400 UNSUPPORTED_FILTER_TYPE", async () => {
    const { status, data } = await post("/api/filters", {
      type: "openai",
      config: {},
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("UNSUPPORTED_FILTER_TYPE");
    expect(data.error.details).toMatchObject({ type: "openai" });
    expect(data.error.details.supportedTypes).toContain("azure");
  });

  test("filters: google type → 400 UNSUPPORTED_FILTER_TYPE", async () => {
    const { status, data } = await post("/api/filters", {
      type: "google",
      config: {},
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("UNSUPPORTED_FILTER_TYPE");
  });

  // ── /api/rag — embedding config propagation → 400 ──────────────────

  test("rag: missing embeddingConfig.modelName → 400 EMBEDDING_CONFIG_INVALID", async () => {
    const { status, data } = await post("/api/rag", {
      input: "test query",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT",
      chatInstruction: "Answer.",
      embeddingConfig: { resourceGroup: "default" },
      chatConfig: { modelName: "gpt-4o", resourceGroup: "default" },
      topK: 3,
    });
    expect(status).toBe(400);
    assertLLMErrorShape(data);
    expect(data.error.code).toBe("EMBEDDING_CONFIG_INVALID");
  });

  // ── Error response never leaks stack traces ─────────────────────────

  test("error response does not contain stack trace", async () => {
    const { data } = await post("/api/chat", {
      config: { resourceGroup: "default" },
      payload: { messages: [{ role: "user", content: "Hi" }] },
    });
    const serialized = JSON.stringify(data);
    expect(serialized).not.toContain("at Object.");
    expect(serialized).not.toContain(".js:");
    expect(serialized).not.toContain("Error:");
  });

  // ── Successful requests are unaffected ──────────────────────────────

  test("valid embedding request still returns 200", async () => {
    const { status, data } = await post("/api/embedding", {
      config: { modelName: "text-embedding-ada-002", resourceGroup: "default" },
      input: "test",
    });
    expect(status).toBe(200);
    expect(data.embeddings).toBeDefined();
    expect(data.error).toBeUndefined();
  });

  test("valid chat request still returns 200", async () => {
    const { status, data } = await post("/api/chat", {
      config: { modelName: "gpt-4o", resourceGroup: "default" },
      payload: { messages: [{ role: "user", content: "Hello" }] },
    });
    expect(status).toBe(200);
    expect(data.result).toBeDefined();
    expect(data.error).toBeUndefined();
  });
});
