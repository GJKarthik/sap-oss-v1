/**
 * E2E Smoke Test — Real HTTP Server
 *
 * Starts the Express E2E server, sends real HTTP requests to the REST
 * endpoints, and verifies responses. This tests the full flow:
 *   HTTP request → Express route → Plugin method → Mocked SDK → HTTP response
 */

const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

let BASE;

describe("E2E Smoke Test — Real HTTP Server", () => {
  let server;

  beforeAll(async () => {
    const { plugin } = setupPlugin();
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => {
    server.close(done);
  });

  async function post(path, body) {
    const res = await fetch(BASE + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    return { status: res.status, data };
  }

  // ── Health check ────────────────────────────────────────────────────

  test("GET /api/health returns OK with endpoint list", async () => {
    const res = await fetch(BASE + "/api/health");
    const data = await res.json();
    expect(res.status).toBe(200);
    expect(data.status).toBe("ok");
    expect(data.endpoints).toContain("/api/chat");
    expect(data.endpoints).toContain("/api/rag");
    expect(data.endpoints).toContain("/api/embedding");
  });

  // ── UI5 page served ─────────────────────────────────────────────────

  test("GET / serves UI5 index.html", async () => {
    const res = await fetch(BASE + "/");
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(html).toContain("CAP LLM Plugin");
    expect(html).toContain("sap-ui-bootstrap");
    expect(html).toContain("Send Chat");
    expect(html).toContain("Send RAG");
  });

  // ── Embedding endpoint ──────────────────────────────────────────────

  test("POST /api/embedding returns 1536-dim vector", async () => {
    const { status, data } = await post("/api/embedding", {
      config: { modelName: "text-embedding-ada-002", resourceGroup: "default" },
      input: "Hello world",
    });
    expect(status).toBe(200);
    expect(data.embeddings).toHaveLength(1);
    expect(data.embeddings[0].embedding).toHaveLength(1536);
  });

  // ── Chat completion endpoint ────────────────────────────────────────

  test("POST /api/chat returns mock AI response", async () => {
    const { status, data } = await post("/api/chat", {
      config: { modelName: "gpt-4o", resourceGroup: "default" },
      payload: { messages: [{ role: "user", content: "What is CAP?" }] },
    });
    expect(status).toBe(200);
    expect(data.result.orchestration_result.choices[0].message.content).toBe(
      "This is a mock AI response.",
    );
    expect(data.result.orchestration_result.choices[0].message.role).toBe("assistant");
  });

  // ── Similarity search endpoint ──────────────────────────────────────

  test("POST /api/search returns similarity results", async () => {
    const embedding = Array.from({ length: 1536 }, () => 0.1);
    const { status, data } = await post("/api/search", {
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      embedding,
      algoName: "COSINE_SIMILARITY",
      topK: 3,
    });
    expect(status).toBe(200);
    expect(data.results).toHaveLength(3);
    expect(data.results[0]).toHaveProperty("PAGE_CONTENT");
    expect(data.results[0]).toHaveProperty("SCORE");
    expect(data.results[0].SCORE).toBe(0.95);
  });

  // ── Content filters endpoint ────────────────────────────────────────

  test("POST /api/filters returns azure content safety filter", async () => {
    const { status, data } = await post("/api/filters", {
      type: "azure",
      config: { Hate: 2, Violence: 2 },
    });
    expect(status).toBe(200);
    expect(data.result.type).toBe("azure_content_safety");
  });

  // ── Harmonized chat endpoint ────────────────────────────────────────

  test("POST /api/harmonized returns chat completion", async () => {
    const { status, data } = await post("/api/harmonized", {
      clientConfig: { promptTemplating: {} },
      chatCompletionConfig: { messages: [{ role: "user", content: "Hello" }] },
    });
    expect(status).toBe(200);
    expect(data.result).toBeDefined();
  });

  // ── Error handling ──────────────────────────────────────────────────

  test("POST /api/chat with missing modelName returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/chat", {
      config: { resourceGroup: "default" },
      payload: { messages: [{ role: "user", content: "Hello" }] },
    });
    expect(status).toBe(400);
    expect(data.error).toBeDefined();
    expect(data.error.code).toBe("CHAT_CONFIG_INVALID");
    expect(data.error.message).toBeDefined();
    expect(data.error.details).toBeDefined();
  });

  test("POST /api/embedding with missing modelName returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/embedding", {
      config: { resourceGroup: "default" },
      input: "test",
    });
    expect(status).toBe(400);
    expect(data.error).toBeDefined();
    expect(data.error.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(data.error.message).toBeDefined();
    expect(data.error.details).toBeDefined();
  });

  test("POST /api/filters with unsupported type returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/filters", {
      type: "unsupported",
      config: {},
    });
    expect(status).toBe(400);
    expect(data.error.code).toBe("UNSUPPORTED_FILTER_TYPE");
    expect(data.error.message).toBeDefined();
    expect(data.error.details).toBeDefined();
  });
});
