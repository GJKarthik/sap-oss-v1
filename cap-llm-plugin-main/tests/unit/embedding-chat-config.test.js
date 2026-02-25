const mockSend = jest.fn(() => Promise.resolve({}));
const mockConnectTo = jest.fn(() => Promise.resolve({ run: jest.fn(), send: mockSend }));

const mockCds = {
  db: { run: jest.fn(), kind: "hana" },
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

beforeEach(() => {
  jest.clearAllMocks();
  mockSend.mockReset().mockResolvedValue({});
  mockConnectTo.mockReset().mockResolvedValue({ run: jest.fn(), send: mockSend });
  mockEmbed.mockReset();
  MockOrchestrationEmbeddingClient.mockClear();
  mockChatCompletion.mockReset();
  MockOrchestrationClient.mockClear();
});

// ── Valid configs ────────────────────────────────────────────────────

const VALID_GPT_EMBEDDING_CONFIG = {
  destinationName: "my-aicore-dest",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/abc123",
  modelName: "text-embedding-ada-002",
  apiVersion: "2024-02-01",
};

const VALID_GPT_CHAT_CONFIG = {
  destinationName: "my-aicore-dest",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/def456",
  modelName: "gpt-4o",
  apiVersion: "2024-02-01",
};

const VALID_GEMINI_CHAT_CONFIG = {
  destinationName: "my-aicore-dest",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/gem789",
  modelName: "gemini-1.0-pro",
  apiVersion: "001",
};

const VALID_CLAUDE_CHAT_CONFIG = {
  destinationName: "my-aicore-dest",
  resourceGroup: "default",
  deploymentUrl: "/v2/inference/deployments/cla012",
  modelName: "anthropic--claude-3-sonnet",
};

// ════════════════════════════════════════════════════════════════════
// getEmbeddingWithConfig
// ════════════════════════════════════════════════════════════════════

describe("getEmbeddingWithConfig", () => {
  describe("valid config — SDK integration", () => {
    test("creates OrchestrationEmbeddingClient with correct model and resourceGroup", async () => {
      const mockResponse = {
        getEmbeddings: () => [{ embedding: [0.1, 0.2, 0.3], index: 0, object: "embedding" }],
      };
      mockEmbed.mockResolvedValue(mockResponse);

      const plugin = createPlugin();
      const result = await plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "Hello world");

      expect(result).toBe(mockResponse);
      // Verify SDK client was constructed with correct args
      expect(MockOrchestrationEmbeddingClient).toHaveBeenCalledTimes(1);
      const ctorArgs = MockOrchestrationEmbeddingClient.mock.calls[0];
      expect(ctorArgs[0]).toEqual({ embeddings: { model: { name: "text-embedding-ada-002" } } });
      expect(ctorArgs[1]).toEqual({ resourceGroup: "default" });
      // Verify embed was called with input
      expect(mockEmbed).toHaveBeenCalledWith({ input: "Hello world" });
    });

    test("works with text-embedding-3-small model", async () => {
      mockEmbed.mockResolvedValue({ getEmbeddings: () => [] });

      const config = { ...VALID_GPT_EMBEDDING_CONFIG, modelName: "text-embedding-3-small" };
      const plugin = createPlugin();
      await plugin.getEmbeddingWithConfig(config, "test");

      expect(MockOrchestrationEmbeddingClient.mock.calls[0][0]).toEqual({
        embeddings: { model: { name: "text-embedding-3-small" } },
      });
    });

    test("works with text-embedding-3-large model", async () => {
      mockEmbed.mockResolvedValue({ getEmbeddings: () => [] });

      const config = { ...VALID_GPT_EMBEDDING_CONFIG, modelName: "text-embedding-3-large" };
      const plugin = createPlugin();
      await plugin.getEmbeddingWithConfig(config, "test");

      expect(MockOrchestrationEmbeddingClient.mock.calls[0][0]).toEqual({
        embeddings: { model: { name: "text-embedding-3-large" } },
      });
    });

    test("passes array input to embed()", async () => {
      mockEmbed.mockResolvedValue({ getEmbeddings: () => [] });

      const plugin = createPlugin();
      await plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, ["text1", "text2"]);

      expect(mockEmbed).toHaveBeenCalledWith({ input: ["text1", "text2"] });
    });

    test("does not call CDS destination (SDK handles connectivity)", async () => {
      mockEmbed.mockResolvedValue({ getEmbeddings: () => [] });

      const plugin = createPlugin();
      await plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "test");

      expect(mockConnectTo).not.toHaveBeenCalled();
      expect(mockSend).not.toHaveBeenCalled();
    });
  });

  describe("missing mandatory params", () => {
    test("throws when modelName is missing", async () => {
      const config = { ...VALID_GPT_EMBEDDING_CONFIG };
      delete config.modelName;

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(config, "test")).rejects.toThrow(/missing the parameter: "modelName"/);
    });

    test("throws when resourceGroup is missing", async () => {
      const config = { ...VALID_GPT_EMBEDDING_CONFIG };
      delete config.resourceGroup;

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(config, "test")).rejects.toThrow(
        /missing the parameter: "resourceGroup"/
      );
    });
  });

  describe("SDK error propagation", () => {
    test("propagates SDK embed() errors", async () => {
      mockEmbed.mockRejectedValue(new Error("Model not found in AI Core"));

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "test")).rejects.toThrow(
        "Model not found in AI Core"
      );
    });

    test("propagates SDK client construction errors", async () => {
      MockOrchestrationEmbeddingClient.mockImplementationOnce(() => {
        throw new Error("Invalid embedding config");
      });

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "test")).rejects.toThrow(
        "Invalid embedding config"
      );
    });
  });

  describe("empty response", () => {
    test("throws when embed returns error", async () => {
      mockEmbed.mockRejectedValue(new Error("Empty response received"));

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "test")).rejects.toThrow(
        /Empty response received/
      );
    });

    test("throws when embed returns undefined", async () => {
      mockEmbed.mockRejectedValue(new Error("Empty response received"));

      const plugin = createPlugin();
      await expect(plugin.getEmbeddingWithConfig(VALID_GPT_EMBEDDING_CONFIG, "test")).rejects.toThrow(
        /Empty response received/
      );
    });
  });
});

// ════════════════════════════════════════════════════════════════════
// getChatCompletionWithConfig
// ════════════════════════════════════════════════════════════════════

describe("getChatCompletionWithConfig", () => {
  const CHAT_PAYLOAD = {
    messages: [{ role: "user", content: "Hello" }],
  };

  describe("valid config — SDK integration", () => {
    test("creates OrchestrationClient with correct model and resourceGroup", async () => {
      const mockResponse = {
        getContent: () => "Hi there!",
        getTokenUsage: () => ({ prompt_tokens: 5, completion_tokens: 10, total_tokens: 15 }),
      };
      mockChatCompletion.mockResolvedValue(mockResponse);

      const plugin = createPlugin();
      const result = await plugin.getChatCompletionWithConfig(VALID_GPT_CHAT_CONFIG, CHAT_PAYLOAD);

      expect(result).toBe(mockResponse);
      // Verify SDK client was constructed with correct args
      expect(MockOrchestrationClient).toHaveBeenCalledTimes(1);
      const ctorArgs = MockOrchestrationClient.mock.calls[0];
      expect(ctorArgs[0]).toEqual({
        promptTemplating: { model: { name: "gpt-4o" } },
      });
      expect(ctorArgs[1]).toEqual({ resourceGroup: "default" });
      // Verify chatCompletion was called with messages
      expect(mockChatCompletion).toHaveBeenCalledWith({
        messages: [{ role: "user", content: "Hello" }],
      });
    });

    test("works with gpt-4 model", async () => {
      mockChatCompletion.mockResolvedValue({ getContent: () => "" });
      const config = { ...VALID_GPT_CHAT_CONFIG, modelName: "gpt-4" };

      const plugin = createPlugin();
      await plugin.getChatCompletionWithConfig(config, CHAT_PAYLOAD);

      expect(MockOrchestrationClient.mock.calls[0][0]).toEqual({
        promptTemplating: { model: { name: "gpt-4" } },
      });
    });

    test("works with gemini model", async () => {
      mockChatCompletion.mockResolvedValue({ getContent: () => "" });

      const plugin = createPlugin();
      await plugin.getChatCompletionWithConfig(VALID_GEMINI_CHAT_CONFIG, {
        messages: [{ role: "user", content: "Hello" }],
      });

      expect(MockOrchestrationClient.mock.calls[0][0]).toEqual({
        promptTemplating: { model: { name: "gemini-1.0-pro" } },
      });
    });

    test("works with claude model", async () => {
      mockChatCompletion.mockResolvedValue({ getContent: () => "" });

      const plugin = createPlugin();
      await plugin.getChatCompletionWithConfig(VALID_CLAUDE_CHAT_CONFIG, CHAT_PAYLOAD);

      expect(MockOrchestrationClient.mock.calls[0][0]).toEqual({
        promptTemplating: { model: { name: "anthropic--claude-3-sonnet" } },
      });
    });

    test("does not call CDS destination (SDK handles connectivity)", async () => {
      mockChatCompletion.mockResolvedValue({ getContent: () => "" });

      const plugin = createPlugin();
      await plugin.getChatCompletionWithConfig(VALID_GPT_CHAT_CONFIG, CHAT_PAYLOAD);

      expect(mockConnectTo).not.toHaveBeenCalled();
      expect(mockSend).not.toHaveBeenCalled();
    });

    test("handles payload with no messages gracefully", async () => {
      mockChatCompletion.mockResolvedValue({ getContent: () => "" });

      const plugin = createPlugin();
      await plugin.getChatCompletionWithConfig(VALID_GPT_CHAT_CONFIG, {});

      expect(mockChatCompletion).toHaveBeenCalledWith({ messages: [] });
    });
  });

  describe("missing mandatory params", () => {
    test("throws when modelName is missing", async () => {
      const config = { ...VALID_GPT_CHAT_CONFIG };
      delete config.modelName;

      const plugin = createPlugin();
      await expect(plugin.getChatCompletionWithConfig(config, CHAT_PAYLOAD)).rejects.toThrow(
        /missing parameter: "modelName"/
      );
    });

    test("throws when resourceGroup is missing", async () => {
      const config = { ...VALID_GPT_CHAT_CONFIG };
      delete config.resourceGroup;

      const plugin = createPlugin();
      await expect(plugin.getChatCompletionWithConfig(config, CHAT_PAYLOAD)).rejects.toThrow(
        /missing parameter: "resourceGroup"/
      );
    });
  });

  describe("SDK error propagation", () => {
    test("propagates SDK chatCompletion() errors", async () => {
      mockChatCompletion.mockRejectedValue(new Error("Model quota exceeded"));

      const plugin = createPlugin();
      await expect(plugin.getChatCompletionWithConfig(VALID_GPT_CHAT_CONFIG, CHAT_PAYLOAD)).rejects.toThrow(
        "Model quota exceeded"
      );
    });

    test("propagates SDK client construction errors", async () => {
      MockOrchestrationClient.mockImplementationOnce(() => {
        throw new Error("Invalid chat config");
      });

      const plugin = createPlugin();
      await expect(plugin.getChatCompletionWithConfig(VALID_GPT_CHAT_CONFIG, CHAT_PAYLOAD)).rejects.toThrow(
        "Invalid chat config"
      );
    });
  });
});
