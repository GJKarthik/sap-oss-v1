/**
 * Integration tests for the full RAG pipeline.
 *
 * Tests the connected flow:
 *   1. getEmbeddingWithConfig (SDK) → embedding vector
 *   2. similaritySearch (HANA SQL) → matching documents
 *   3. System prompt construction with similar content
 *   4. getChatCompletionWithConfig (SDK) → chat response
 *   5. RagResponse shape { completion, additionalContents }
 *
 * All external dependencies (HANA, AI SDK) are mocked, but the
 * internal wiring between methods is exercised as a connected unit.
 */

// ── DB mock ──────────────────────────────────────────────────────────
const mockDbRun = jest.fn(() => Promise.resolve([]));
const mockDbConnect = jest.fn(() => Promise.resolve({ run: mockDbRun }));

const mockCds = {
  db: { run: mockDbRun, kind: "hana" },
  connect: { to: mockDbConnect },
  services: {},
  log: jest.fn(() => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() })),
  env: { requires: {} },
  requires: {},
  Service: class MockService {
    async init() {}
  },
  once: jest.fn(),
};

jest.mock("@sap/cds", () => mockCds, { virtual: true });

// ── SDK mocks ────────────────────────────────────────────────────────
const mockEmbed = jest.fn();
const MockOrchestrationEmbeddingClient = jest.fn().mockImplementation(() => ({
  embed: mockEmbed,
}));

const mockChatCompletion = jest.fn();
const MockOrchestrationClient = jest.fn().mockImplementation(() => ({
  chatCompletion: mockChatCompletion,
}));

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: MockOrchestrationEmbeddingClient,
  OrchestrationClient: MockOrchestrationClient,
  buildAzureContentSafetyFilter: jest.fn(),
}));

const CAPLLMPlugin = require("../../srv/cap-llm-plugin");

function createPlugin() {
  return new CAPLLMPlugin();
}

// ── Fixtures ─────────────────────────────────────────────────────────

const EMBEDDING_CONFIG = {
  destinationName: "aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/emb",
  modelName: "text-embedding-ada-002",
  apiVersion: "2024-02-01",
};

const CHAT_CONFIG = {
  destinationName: "aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/chat",
  modelName: "gpt-4o",
  apiVersion: "2024-02-01",
};

const MOCK_EMBEDDING_VECTOR = [0.12, 0.34, 0.56, 0.78, 0.9];

const MOCK_EMBEDDING_RESPONSE = {
  getEmbeddings: () => [{ embedding: MOCK_EMBEDDING_VECTOR, index: 0 }],
};

const MOCK_SIMILARITY_RESULTS = [
  { PAGE_CONTENT: "SAP HANA is an in-memory database.", SCORE: 0.95 },
  { PAGE_CONTENT: "CAP provides a framework for cloud services.", SCORE: 0.88 },
  { PAGE_CONTENT: "AI Core manages ML model deployments.", SCORE: 0.82 },
];

const MOCK_CHAT_RESPONSE = {
  getContent: () => "Based on the context, SAP HANA is an in-memory database platform.",
  getTokenUsage: () => ({ prompt_tokens: 50, completion_tokens: 20, total_tokens: 70 }),
  getFinishReason: () => "stop",
};

// ═════════════════════════════════════════════════════════════════════

beforeEach(() => {
  jest.clearAllMocks();

  mockEmbed.mockResolvedValue(MOCK_EMBEDDING_RESPONSE);
  MockOrchestrationEmbeddingClient.mockClear();

  mockChatCompletion.mockResolvedValue(MOCK_CHAT_RESPONSE);
  MockOrchestrationClient.mockClear();

  mockDbRun.mockResolvedValue(MOCK_SIMILARITY_RESULTS);
  mockDbConnect.mockResolvedValue({ run: mockDbRun });
});

// ═════════════════════════════════════════════════════════════════════
// Full RAG Pipeline
// ═════════════════════════════════════════════════════════════════════

describe("RAG pipeline integration", () => {
  describe("end-to-end flow", () => {
    test("embed → search → chat: returns RagResponse with correct shape", async () => {
      const plugin = createPlugin();

      const result = await plugin.getRagResponseWithConfig(
        "What is SAP HANA?",
        "DOCUMENTS",
        "EMBEDDING",
        "CONTENT",
        "Answer using the provided context.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      // Verify response shape
      expect(result).toHaveProperty("completion");
      expect(result).toHaveProperty("additionalContents");
      expect(result.completion).toBe(MOCK_CHAT_RESPONSE);
      expect(result.additionalContents).toEqual(MOCK_SIMILARITY_RESULTS);
    });

    test("embedding client receives the user query as input", async () => {
      const plugin = createPlugin();

      await plugin.getRagResponseWithConfig(
        "What is SAP HANA?",
        "DOCUMENTS",
        "EMBEDDING",
        "CONTENT",
        "Answer.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      // Verify embedding SDK was called with user input
      expect(MockOrchestrationEmbeddingClient).toHaveBeenCalledTimes(1);
      expect(MockOrchestrationEmbeddingClient.mock.calls[0][0]).toEqual({
        embeddings: { model: { name: "text-embedding-ada-002" } },
      });
      expect(mockEmbed).toHaveBeenCalledWith(
        { input: "What is SAP HANA?" },
        expect.objectContaining({ middleware: expect.any(Array) })
      );
    });

    test("similarity search SQL uses embedding vector from SDK response", async () => {
      const plugin = createPlugin();

      await plugin.getRagResponseWithConfig(
        "Query",
        "MY_TABLE",
        "EMB_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      // Verify HANA similarity search was called with the embedding vector
      expect(mockDbRun).toHaveBeenCalledTimes(1);
      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toContain("MY_TABLE");
      expect(sql).toContain("EMB_COL");
      expect(sql).toContain("CONTENT_COL");
      expect(sql).toContain("COSINE_SIMILARITY");
      expect(sql).toContain("0.12,0.34,0.56,0.78,0.9");
      expect(sql).toContain("TOP 3");
    });

    test("chat completion receives system prompt with similar content injected", async () => {
      const plugin = createPlugin();

      await plugin.getRagResponseWithConfig(
        "Tell me about HANA",
        "DOCS",
        "EMB",
        "TEXT",
        "Use the following context to answer.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      // Verify OrchestrationClient was constructed with chat model
      expect(MockOrchestrationClient).toHaveBeenCalledTimes(1);
      expect(MockOrchestrationClient.mock.calls[0][0]).toEqual({
        promptTemplating: { model: { name: "gpt-4o" } },
      });
      expect(MockOrchestrationClient.mock.calls[0][1]).toEqual({
        resourceGroup: "default",
      });

      // Verify chatCompletion was called with messages containing similar content
      expect(mockChatCompletion).toHaveBeenCalledTimes(1);
      const chatArgs = mockChatCompletion.mock.calls[0][0];
      expect(chatArgs.messages).toHaveLength(2); // system + user

      const systemMsg = chatArgs.messages[0];
      expect(systemMsg.role).toBe("system");
      expect(systemMsg.content).toContain("Use the following context to answer.");
      expect(systemMsg.content).toContain("SAP HANA is an in-memory database.");
      expect(systemMsg.content).toContain("CAP provides a framework for cloud services.");
      expect(systemMsg.content).toContain("AI Core manages ML model deployments.");

      const userMsg = chatArgs.messages[1];
      expect(userMsg.role).toBe("user");
      expect(userMsg.content).toBe("Tell me about HANA");
    });

    test("passes conversation context into the messages array", async () => {
      const context = [
        { role: "user", content: "What databases does SAP offer?" },
        { role: "assistant", content: "SAP offers HANA, ASE, and IQ." },
      ];

      const plugin = createPlugin();

      await plugin.getRagResponseWithConfig(
        "Tell me more about HANA",
        "DOCS",
        "EMB",
        "TEXT",
        "Answer based on context.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG,
        context
      );

      const chatArgs = mockChatCompletion.mock.calls[0][0];
      // messages: [system, ...context, user]
      expect(chatArgs.messages).toHaveLength(4);
      expect(chatArgs.messages[0].role).toBe("system");
      expect(chatArgs.messages[1]).toEqual({ role: "user", content: "What databases does SAP offer?" });
      expect(chatArgs.messages[2]).toEqual({ role: "assistant", content: "SAP offers HANA, ASE, and IQ." });
      expect(chatArgs.messages[3]).toEqual({ role: "user", content: "Tell me more about HANA" });
    });

    test("uses custom topK and algoName", async () => {
      const plugin = createPlugin();

      await plugin.getRagResponseWithConfig(
        "Query",
        "MY_TABLE",
        "EMB_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG,
        undefined,
        10,
        "L2DISTANCE"
      );

      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toContain("TOP 10");
      expect(sql).toContain("L2DISTANCE");
      expect(sql).toContain("ORDER BY SCORE ASC");
    });
  });

  describe("error propagation through the pipeline", () => {
    test("embedding failure prevents similarity search and chat", async () => {
      mockEmbed.mockRejectedValue(new Error("Embedding model unavailable"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig("Query", "T", "E", "C", "I", EMBEDDING_CONFIG, CHAT_CONFIG)
      ).rejects.toThrow("Embedding model unavailable");

      // Verify downstream steps were NOT called
      expect(mockDbRun).not.toHaveBeenCalled();
      expect(mockChatCompletion).not.toHaveBeenCalled();
    });

    test("similarity search failure prevents chat completion", async () => {
      mockDbRun.mockRejectedValue(new Error("HANA connection refused"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig("Query", "T", "E", "C", "I", EMBEDDING_CONFIG, CHAT_CONFIG)
      ).rejects.toThrow("HANA connection refused");

      // Embedding was called, but chat was NOT
      expect(mockEmbed).toHaveBeenCalledTimes(1);
      expect(mockChatCompletion).not.toHaveBeenCalled();
    });

    test("chat completion failure propagates after successful embed + search", async () => {
      mockChatCompletion.mockRejectedValue(new Error("Token limit exceeded"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig("Query", "T", "E", "C", "I", EMBEDDING_CONFIG, CHAT_CONFIG)
      ).rejects.toThrow("Token limit exceeded");

      // Both embedding and similarity search were called
      expect(mockEmbed).toHaveBeenCalledTimes(1);
      expect(mockDbRun).toHaveBeenCalledTimes(1);
    });

    test("invalid embedding config throws before SDK call", async () => {
      const badConfig = { ...EMBEDDING_CONFIG };
      delete badConfig.modelName;

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig("Query", "T", "E", "C", "I", badConfig, CHAT_CONFIG)
      ).rejects.toThrow(/missing the parameter: "modelName"/);

      expect(mockEmbed).not.toHaveBeenCalled();
    });

    test("invalid similarity search algorithm throws", async () => {
      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig(
          "Query",
          "T",
          "E",
          "C",
          "I",
          EMBEDDING_CONFIG,
          CHAT_CONFIG,
          undefined,
          3,
          "INVALID_ALGO"
        )
      ).rejects.toThrow(/Invalid algorithm name/);

      // Embedding was called but chat was not
      expect(mockEmbed).toHaveBeenCalledTimes(1);
      expect(mockChatCompletion).not.toHaveBeenCalled();
    });
  });

  describe("individual method integration", () => {
    test("getEmbeddingWithConfig returns SDK response directly", async () => {
      const plugin = createPlugin();
      const result = await plugin.getEmbeddingWithConfig(EMBEDDING_CONFIG, "test input");

      expect(result).toBe(MOCK_EMBEDDING_RESPONSE);
      expect(result.getEmbeddings()[0].embedding).toEqual(MOCK_EMBEDDING_VECTOR);
    });

    test("getChatCompletionWithConfig returns SDK response directly", async () => {
      const plugin = createPlugin();
      const result = await plugin.getChatCompletionWithConfig(CHAT_CONFIG, {
        messages: [{ role: "user", content: "Hello" }],
      });

      expect(result).toBe(MOCK_CHAT_RESPONSE);
    });

    test("similaritySearch constructs correct SQL and returns DB results", async () => {
      const plugin = createPlugin();
      const embedding = [0.1, 0.2, 0.3];

      const result = await plugin.similaritySearch(
        "MY_TABLE",
        "EMB_COL",
        "CONTENT_COL",
        embedding,
        "COSINE_SIMILARITY",
        5
      );

      expect(result).toEqual(MOCK_SIMILARITY_RESULTS);
      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toMatch(/SELECT TOP 5/);
      expect(sql).toContain("COSINE_SIMILARITY");
      expect(sql).toContain("0.1,0.2,0.3");
    });
  });
});
