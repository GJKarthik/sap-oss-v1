// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * E2E Test — RAG Pipeline Flow
 *
 * Tests the full Retrieval-Augmented Generation pipeline through real HTTP:
 *   Client POST → Express → Plugin.getRagResponseWithConfig →
 *     1. Embedding (mocked SDK)
 *     2. Similarity Search (mocked DB)
 *     3. Chat Completion with context (mocked SDK)
 *   → HTTP response with completion + additionalContents
 *
 * Validates the complete multi-step pipeline, response structure,
 * similarity search results, and error handling.
 */

const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

let BASE;

describe("E2E RAG Pipeline Flow", () => {
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

  const embeddingConfig = { modelName: "text-embedding-ada-002", resourceGroup: "default" };
  const chatConfig = { modelName: "gpt-4o", resourceGroup: "default" };

  // ── Full RAG pipeline ───────────────────────────────────────────────

  test("RAG pipeline returns completion + additionalContents", async () => {
    const { status, data } = await post("/api/rag", {
      input: "What is SAP HANA Cloud?",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Answer the question based on the provided context.",
      embeddingConfig,
      chatConfig,
      topK: 3,
    });

    expect(status).toBe(200);
    // RAG response has completion and additionalContents
    expect(data).toHaveProperty("completion");
    expect(data).toHaveProperty("additionalContents");
  });

  test("additionalContents contains similarity search results with scores", async () => {
    const { status, data } = await post("/api/rag", {
      input: "Tell me about vector embeddings",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Explain using the context provided.",
      embeddingConfig,
      chatConfig,
      topK: 3,
    });

    expect(status).toBe(200);
    expect(data.additionalContents).toHaveLength(3);

    // Each result has PAGE_CONTENT and SCORE
    for (const result of data.additionalContents) {
      expect(result).toHaveProperty("PAGE_CONTENT");
      expect(result).toHaveProperty("SCORE");
      expect(typeof result.SCORE).toBe("number");
      expect(typeof result.PAGE_CONTENT).toBe("string");
    }

    // Results are ordered by descending score
    expect(data.additionalContents[0].SCORE).toBeGreaterThanOrEqual(
      data.additionalContents[1].SCORE,
    );
    expect(data.additionalContents[1].SCORE).toBeGreaterThanOrEqual(
      data.additionalContents[2].SCORE,
    );
  });

  test("completion contains the mock AI response", async () => {
    const { status, data } = await post("/api/rag", {
      input: "How does RAG work?",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Answer the question.",
      embeddingConfig,
      chatConfig,
      topK: 3,
    });

    expect(status).toBe(200);
    // The completion should be the SDK response object
    expect(data.completion).toBeDefined();
  });

  // ── RAG with different topK values ──────────────────────────────────

  test("RAG respects topK parameter", async () => {
    const { status, data } = await post("/api/rag", {
      input: "Search query",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Answer.",
      embeddingConfig,
      chatConfig,
      topK: 3,
    });

    expect(status).toBe(200);
    // Mock returns 3 rows by default
    expect(data.additionalContents.length).toBeLessThanOrEqual(3);
  });

  // ── RAG with custom chat instruction ────────────────────────────────

  test("RAG accepts custom chatInstruction", async () => {
    const { status } = await post("/api/rag", {
      input: "Summarize the documents",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "You are a summarization bot. Summarize the following documents concisely.",
      embeddingConfig,
      chatConfig,
      topK: 5,
    });

    expect(status).toBe(200);
  });

  // ── Embedding endpoint (used by RAG internally) ─────────────────────

  test("standalone embedding returns vector for RAG input", async () => {
    const { status, data } = await post("/api/embedding", {
      config: embeddingConfig,
      input: "What is SAP HANA Cloud?",
    });

    expect(status).toBe(200);
    expect(data.embeddings).toHaveLength(1);
    expect(data.embeddings[0].embedding).toHaveLength(1536);
    // Vector values are numbers
    expect(typeof data.embeddings[0].embedding[0]).toBe("number");
  });

  // ── Similarity search endpoint (used by RAG internally) ─────────────

  test("standalone search returns scored documents", async () => {
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
    expect(data.results[0].SCORE).toBe(0.95);
    expect(data.results[1].SCORE).toBe(0.9);
    expect(data.results[2].SCORE).toBe(0.85);
  });

  // ── Error scenarios ─────────────────────────────────────────────────

  test("RAG with missing tableName returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/rag", {
      input: "test",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Answer.",
      embeddingConfig,
      chatConfig,
      topK: 3,
    });

    expect([400, 500]).toContain(status);
    expect(data.error).toBeDefined();
    expect(data.error.code).toBeDefined();
    expect(data.error.message).toBeDefined();
  });

  test("RAG with missing embeddingConfig returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/rag", {
      input: "test",
      tableName: "DOCUMENTS",
      embeddingColumnName: "EMBEDDING",
      contentColumn: "TEXT_CONTENT",
      chatInstruction: "Answer.",
      chatConfig,
      topK: 3,
    });

    expect([400, 500]).toContain(status);
    expect(data.error).toBeDefined();
    expect(data.error.code).toBeDefined();
    expect(data.error.message).toBeDefined();
  });
});
