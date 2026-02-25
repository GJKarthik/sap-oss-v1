/**
 * Integration tests for the orchestration layer:
 *   - getHarmonizedChatCompletion (OrchestrationClient)
 *   - getContentFilters (buildAzureContentSafetyFilter)
 *
 * These tests verify the connected flow between the plugin methods
 * and the SDK, including flag-based response extraction, error
 * propagation, and content filter construction.
 */

// ── SDK mocks ────────────────────────────────────────────────────────
const mockChatCompletion = jest.fn();
const mockGetContent = jest.fn(() => "Generated response content");
const mockGetTokenUsage = jest.fn(() => ({
  prompt_tokens: 25,
  completion_tokens: 40,
  total_tokens: 65,
}));
const mockGetFinishReason = jest.fn(() => "stop");

const mockOrchestrationResponse = {
  getContent: mockGetContent,
  getTokenUsage: mockGetTokenUsage,
  getFinishReason: mockGetFinishReason,
};

mockChatCompletion.mockResolvedValue(mockOrchestrationResponse);

const MockOrchestrationClient = jest.fn().mockImplementation(() => ({
  chatCompletion: mockChatCompletion,
}));

const mockBuildAzureContentSafetyFilter = jest.fn(() => ({
  type: "azure_content_safety",
  config: { Hate: 2, Violence: 2, SelfHarm: 0, Sexual: 0 },
}));

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationClient: MockOrchestrationClient,
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: jest.fn() })),
  buildAzureContentSafetyFilter: mockBuildAzureContentSafetyFilter,
}));

const mockCds = {
  db: { run: jest.fn(), kind: "hana" },
  connect: { to: jest.fn() },
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

const CAPLLMPlugin = require("../../srv/cap-llm-plugin");

function createPlugin() {
  return new CAPLLMPlugin();
}

// ── Fixtures ─────────────────────────────────────────────────────────

const CLIENT_CONFIG = {
  promptTemplating: {
    model: { name: "gpt-4o", version: "latest" },
  },
};

const CHAT_COMPLETION_CONFIG = {
  messages: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: "What is SAP BTP?" },
  ],
};

// ═════════════════════════════════════════════════════════════════════

beforeEach(() => {
  jest.clearAllMocks();
  mockChatCompletion.mockResolvedValue(mockOrchestrationResponse);
  MockOrchestrationClient.mockClear();
  mockBuildAzureContentSafetyFilter.mockReset().mockReturnValue({
    type: "azure_content_safety",
    config: { Hate: 2, Violence: 2, SelfHarm: 0, Sexual: 0 },
  });
  mockGetContent.mockReturnValue("Generated response content");
  mockGetTokenUsage.mockReturnValue({
    prompt_tokens: 25,
    completion_tokens: 40,
    total_tokens: 65,
  });
  mockGetFinishReason.mockReturnValue("stop");
});

// ═════════════════════════════════════════════════════════════════════
// getHarmonizedChatCompletion
// ═════════════════════════════════════════════════════════════════════

describe("getHarmonizedChatCompletion — integration", () => {
  describe("client initialization", () => {
    test("creates OrchestrationClient with provided clientConfig", async () => {
      const plugin = createPlugin();

      await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(MockOrchestrationClient).toHaveBeenCalledTimes(1);
      expect(MockOrchestrationClient).toHaveBeenCalledWith(CLIENT_CONFIG);
    });

    test("passes chatCompletionConfig to chatCompletion()", async () => {
      const plugin = createPlugin();

      await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(mockChatCompletion).toHaveBeenCalledTimes(1);
      expect(mockChatCompletion).toHaveBeenCalledWith(CHAT_COMPLETION_CONFIG);
    });
  });

  describe("flag behavior", () => {
    test("returns full response when no flags set", async () => {
      const plugin = createPlugin();

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(result).toBe(mockOrchestrationResponse);
      expect(mockGetContent).not.toHaveBeenCalled();
      expect(mockGetTokenUsage).not.toHaveBeenCalled();
      expect(mockGetFinishReason).not.toHaveBeenCalled();
    });

    test("returns content when getContent=true", async () => {
      const plugin = createPlugin();

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getContent: true,
      });

      expect(result).toBe("Generated response content");
      expect(mockGetContent).toHaveBeenCalledTimes(1);
    });

    test("returns token usage when getTokenUsage=true", async () => {
      const plugin = createPlugin();

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getTokenUsage: true,
      });

      expect(result).toEqual({
        prompt_tokens: 25,
        completion_tokens: 40,
        total_tokens: 65,
      });
      expect(mockGetTokenUsage).toHaveBeenCalledTimes(1);
    });

    test("returns finish reason when getFinishReason=true", async () => {
      const plugin = createPlugin();

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getFinishReason: true,
      });

      expect(result).toBe("stop");
      expect(mockGetFinishReason).toHaveBeenCalledTimes(1);
    });

    test("getContent takes priority when multiple flags are true", async () => {
      const plugin = createPlugin();

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getContent: true,
        getTokenUsage: true,
        getFinishReason: true,
      });

      // getContent is checked first in the switch
      expect(result).toBe("Generated response content");
      expect(mockGetContent).toHaveBeenCalledTimes(1);
      expect(mockGetTokenUsage).not.toHaveBeenCalled();
      expect(mockGetFinishReason).not.toHaveBeenCalled();
    });
  });

  describe("advanced config", () => {
    test("works with complex clientConfig including filtering and templating", async () => {
      const complexConfig = {
        promptTemplating: {
          model: { name: "gpt-4o" },
        },
        inputFiltering: {
          filters: [{ type: "azure_content_safety", config: { Hate: 4 } }],
        },
      };

      const plugin = createPlugin();

      await plugin.getHarmonizedChatCompletion({
        clientConfig: complexConfig,
        chatCompletionConfig: {
          messages: [{ role: "user", content: "Test" }],
        },
      });

      expect(MockOrchestrationClient).toHaveBeenCalledWith(complexConfig);
    });

    test("works with messagesHistory in chatCompletionConfig", async () => {
      const configWithHistory = {
        messages: [{ role: "user", content: "Follow-up question" }],
        messagesHistory: [
          { role: "user", content: "First question" },
          { role: "assistant", content: "First answer" },
        ],
      };

      const plugin = createPlugin();

      await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: configWithHistory,
      });

      expect(mockChatCompletion).toHaveBeenCalledWith(configWithHistory);
    });
  });

  describe("error handling", () => {
    test("propagates OrchestrationClient construction errors", async () => {
      MockOrchestrationClient.mockImplementationOnce(() => {
        throw new Error("Invalid orchestration config");
      });

      const plugin = createPlugin();
      await expect(
        plugin.getHarmonizedChatCompletion({
          clientConfig: CLIENT_CONFIG,
          chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        })
      ).rejects.toThrow("Invalid orchestration config");
    });

    test("propagates chatCompletion errors", async () => {
      mockChatCompletion.mockRejectedValue(new Error("Rate limit exceeded"));

      const plugin = createPlugin();
      await expect(
        plugin.getHarmonizedChatCompletion({
          clientConfig: CLIENT_CONFIG,
          chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        })
      ).rejects.toThrow("Rate limit exceeded");
    });

    test("propagates getContent errors", async () => {
      mockGetContent.mockImplementation(() => {
        throw new Error("No content in response");
      });

      const plugin = createPlugin();
      await expect(
        plugin.getHarmonizedChatCompletion({
          clientConfig: CLIENT_CONFIG,
          chatCompletionConfig: CHAT_COMPLETION_CONFIG,
          getContent: true,
        })
      ).rejects.toThrow("No content in response");
    });
  });
});

// ═════════════════════════════════════════════════════════════════════
// getContentFilters
// ═════════════════════════════════════════════════════════════════════

describe("getContentFilters — integration", () => {
  describe("azure type", () => {
    test("returns azure content safety filter with config", async () => {
      const plugin = createPlugin();

      const result = await plugin.getContentFilters({
        type: "azure",
        config: { Hate: 2, Violence: 2, SelfHarm: 0, Sexual: 0 },
      });

      expect(result).toEqual({
        type: "azure_content_safety",
        config: { Hate: 2, Violence: 2, SelfHarm: 0, Sexual: 0 },
      });
      expect(mockBuildAzureContentSafetyFilter).toHaveBeenCalledWith({
        Hate: 2,
        Violence: 2,
        SelfHarm: 0,
        Sexual: 0,
      });
    });

    test("works with uppercase 'Azure'", async () => {
      const plugin = createPlugin();

      await plugin.getContentFilters({ type: "Azure", config: {} });

      expect(mockBuildAzureContentSafetyFilter).toHaveBeenCalledTimes(1);
    });

    test("works with uppercase 'AZURE'", async () => {
      const plugin = createPlugin();

      await plugin.getContentFilters({ type: "AZURE", config: {} });

      expect(mockBuildAzureContentSafetyFilter).toHaveBeenCalledTimes(1);
    });
  });

  describe("unsupported type", () => {
    test("throws for unsupported filter type", async () => {
      const plugin = createPlugin();

      await expect(plugin.getContentFilters({ type: "google", config: {} })).rejects.toThrow(/Unsupported type google/);
    });

    test("throws with helpful message mentioning azure", async () => {
      const plugin = createPlugin();

      await expect(plugin.getContentFilters({ type: "custom", config: {} })).rejects.toThrow(
        /currently supported type is 'azure'/
      );
    });
  });

  describe("error handling", () => {
    test("propagates buildAzureContentSafetyFilter errors", async () => {
      mockBuildAzureContentSafetyFilter.mockImplementation(() => {
        throw new Error("Invalid filter configuration");
      });

      const plugin = createPlugin();
      await expect(plugin.getContentFilters({ type: "azure", config: { bad: true } })).rejects.toThrow(
        "Invalid filter configuration"
      );
    });
  });

  describe("combined with getHarmonizedChatCompletion", () => {
    test("content filter result can be used in orchestration config", async () => {
      const plugin = createPlugin();

      // Step 1: Get content filter
      const filter = await plugin.getContentFilters({
        type: "azure",
        config: { Hate: 4, Violence: 4 },
      });

      // Step 2: Use filter in harmonized chat completion
      const clientConfig = {
        promptTemplating: { model: { name: "gpt-4o" } },
        inputFiltering: { filters: [filter] },
      };

      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig,
        chatCompletionConfig: {
          messages: [{ role: "user", content: "Hello" }],
        },
        getContent: true,
      });

      expect(result).toBe("Generated response content");
      expect(MockOrchestrationClient).toHaveBeenCalledWith(clientConfig);
    });
  });
});
