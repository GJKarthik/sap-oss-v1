const mockSend = jest.fn(() => Promise.resolve({}));
const mockDbRun = jest.fn(() => Promise.resolve([]));
const mockConnectTo = jest.fn((service) => {
  if (service === "db") {
    return Promise.resolve({ run: mockDbRun });
  }
  return Promise.resolve({ run: jest.fn(), send: mockSend });
});

const mockCds = {
  db: { run: mockDbRun, kind: "hana" },
  connect: { to: mockConnectTo },
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

// ── Shared fixtures ─────────────────────────────────────────────────

const EMBEDDING_CONFIG = {
  destinationName: "my-aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/emb123",
  modelName: "text-embedding-ada-002",
  apiVersion: "2024-02-01",
};

const CHAT_CONFIG = {
  destinationName: "my-aicore",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/chat456",
  modelName: "gpt-4o",
  apiVersion: "2024-02-01",
};

const MOCK_EMBEDDING_VECTOR = [0.1, 0.2, 0.3, 0.4, 0.5];

const MOCK_EMBEDDING_RESPONSE = {
  getEmbeddings: () => [{ embedding: MOCK_EMBEDDING_VECTOR, index: 0, object: "embedding" }],
};

const MOCK_SIMILARITY_RESULTS = [
  { PAGE_CONTENT: "SAP HANA is an in-memory database.", SCORE: 0.95 },
  { PAGE_CONTENT: "CAP is a framework for services.", SCORE: 0.88 },
  { PAGE_CONTENT: "AI Core manages models.", SCORE: 0.82 },
];

const MOCK_CHAT_RESPONSE = {
  choices: [
    {
      message: {
        role: "assistant",
        content: "Based on the context, SAP HANA is an in-memory database.",
      },
    },
  ],
};

beforeEach(() => {
  jest.clearAllMocks();

  // Embedding SDK mock returns mock embedding response
  mockEmbed.mockResolvedValue(MOCK_EMBEDDING_RESPONSE);
  MockOrchestrationEmbeddingClient.mockClear();

  // Chat completion SDK mock returns mock chat response
  mockChatCompletion.mockResolvedValue(MOCK_CHAT_RESPONSE);
  MockOrchestrationClient.mockClear();

  // Similarity search DB call returns mock results
  mockDbRun.mockResolvedValue(MOCK_SIMILARITY_RESULTS);

  // Route connect.to calls (only DB needed now)
  mockConnectTo.mockImplementation((service) => {
    if (service === "db") {
      return Promise.resolve({ run: mockDbRun });
    }
    return Promise.resolve({ run: jest.fn(), send: mockSend });
  });
});

// ════════════════════════════════════════════════════════════════════
// getRagResponseWithConfig
// ════════════════════════════════════════════════════════════════════

describe("getRagResponseWithConfig", () => {
  describe("full RAG pipeline — happy path", () => {
    test("returns completion and additionalContents", async () => {
      const plugin = createPlugin();
      const result = await plugin.getRagResponseWithConfig(
        "What is HANA?",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Answer based on the content which is enclosed in triple quotes.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG,
        undefined, // context
        3,
        "COSINE_SIMILARITY",
        undefined // chatParams
      );

      expect(result).toHaveProperty("completion");
      expect(result).toHaveProperty("additionalContents");
      expect(result.completion).toEqual(MOCK_CHAT_RESPONSE);
      expect(result.additionalContents).toEqual(MOCK_SIMILARITY_RESULTS);
    });

    test("calls getEmbeddingWithConfig with correct args", async () => {
      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "getEmbeddingWithConfig");

      await plugin.getRagResponseWithConfig(
        "User query",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      expect(spy).toHaveBeenCalledWith(EMBEDDING_CONFIG, "User query");
    });

    test("calls similaritySearch with embedding from getEmbeddingWithConfig", async () => {
      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "similaritySearch");

      await plugin.getRagResponseWithConfig(
        "User query",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG,
        undefined,
        5,
        "L2DISTANCE"
      );

      expect(spy).toHaveBeenCalledWith(
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        [0.1, 0.2, 0.3, 0.4, 0.5], // embedding extracted from mock response
        "L2DISTANCE",
        5
      );
    });

    test("builds system prompt with similar content and chat instruction", async () => {
      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "getChatCompletionWithConfig");

      await plugin.getRagResponseWithConfig(
        "User query",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Answer based on context.",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      expect(spy).toHaveBeenCalledTimes(1);
      const payload = spy.mock.calls[0][1];
      const systemMsg = payload.messages[0];
      expect(systemMsg.role).toBe("system");
      expect(systemMsg.content).toContain("Answer based on context.");
      expect(systemMsg.content).toContain("SAP HANA is an in-memory database.");
      expect(systemMsg.content).toContain("CAP is a framework for services.");
    });

    test("calls getChatCompletionWithConfig with built payload", async () => {
      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "getChatCompletionWithConfig");

      await plugin.getRagResponseWithConfig(
        "User query",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy.mock.calls[0][0]).toEqual(CHAT_CONFIG);
      // Payload should have messages array
      const payload = spy.mock.calls[0][1];
      expect(payload.messages).toBeDefined();
    });

    test("passes context through the messages array", async () => {
      const context = [
        { role: "user", content: "Previous Q" },
        { role: "assistant", content: "Previous A" },
      ];

      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "getChatCompletionWithConfig");

      await plugin.getRagResponseWithConfig(
        "Follow-up",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG,
        context,
        3,
        "COSINE_SIMILARITY"
      );

      const payload = spy.mock.calls[0][1];
      // messages: [system, ...context, user]
      expect(payload.messages).toHaveLength(4);
      expect(payload.messages[0].role).toBe("system");
      expect(payload.messages[1]).toEqual({ role: "user", content: "Previous Q" });
      expect(payload.messages[2]).toEqual({ role: "assistant", content: "Previous A" });
      expect(payload.messages[3]).toEqual({ role: "user", content: "Follow-up" });
    });

    test("uses default topK=3 and algoName=COSINE_SIMILARITY", async () => {
      const plugin = createPlugin();
      const spy = jest.spyOn(plugin, "similaritySearch");

      await plugin.getRagResponseWithConfig(
        "Query",
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        "Instruction",
        EMBEDDING_CONFIG,
        CHAT_CONFIG
      );

      expect(spy.mock.calls[0][4]).toBe("COSINE_SIMILARITY");
      expect(spy.mock.calls[0][5]).toBe(3);
    });
  });

  describe("error handling", () => {
    test("throws when embedding call fails", async () => {
      mockEmbed.mockRejectedValue(new Error("Embedding service down"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig(
          "Query",
          "MY_TABLE",
          "EMBEDDING_COL",
          "CONTENT_COL",
          "Instruction",
          EMBEDDING_CONFIG,
          CHAT_CONFIG
        )
      ).rejects.toThrow("Embedding service down");
    });

    test("throws when similarity search fails", async () => {
      mockDbRun.mockRejectedValue(new Error("HANA unavailable"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig(
          "Query",
          "MY_TABLE",
          "EMBEDDING_COL",
          "CONTENT_COL",
          "Instruction",
          EMBEDDING_CONFIG,
          CHAT_CONFIG
        )
      ).rejects.toThrow("HANA unavailable");
    });

    test("throws when chat completion fails", async () => {
      mockChatCompletion.mockRejectedValue(new Error("Chat model overloaded"));

      const plugin = createPlugin();
      await expect(
        plugin.getRagResponseWithConfig(
          "Query",
          "MY_TABLE",
          "EMBEDDING_COL",
          "CONTENT_COL",
          "Instruction",
          EMBEDDING_CONFIG,
          CHAT_CONFIG
        )
      ).rejects.toThrow("Chat model overloaded");
    });
  });
});
