// Mock the OrchestrationClient and buildAzureContentSafetyFilter
const mockChatCompletion = jest.fn();
const mockGetContent = jest.fn(() => "AI-generated response content");
const mockGetTokenUsage = jest.fn(() => ({ prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 }));
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
  config: { Hate: 2, Violence: 2 },
}));

// Mock the dynamic import of @sap-ai-sdk/orchestration
jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationClient: MockOrchestrationClient,
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({
    embed: jest.fn(),
  })),
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

beforeEach(() => {
  jest.clearAllMocks();
  mockChatCompletion.mockResolvedValue(mockOrchestrationResponse);
  mockGetContent.mockReturnValue("AI-generated response content");
  mockGetTokenUsage.mockReturnValue({ prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 });
  mockGetFinishReason.mockReturnValue("stop");
});

// ════════════════════════════════════════════════════════════════════
// getHarmonizedChatCompletion
// ════════════════════════════════════════════════════════════════════

describe("getHarmonizedChatCompletion", () => {
  const CLIENT_CONFIG = {
    promptTemplating: {
      model: { name: "gpt-4o" },
      prompt: { template: "Hello {{?name}}" },
    },
  };
  const CHAT_COMPLETION_CONFIG = {
    placeholderValues: { name: "World" },
  };

  describe("flag behavior", () => {
    test("returns full response when no flags set", async () => {
      const plugin = createPlugin();
      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(result).toBe(mockOrchestrationResponse);
      expect(MockOrchestrationClient).toHaveBeenCalledWith(CLIENT_CONFIG);
      expect(mockChatCompletion).toHaveBeenCalledWith(CHAT_COMPLETION_CONFIG);
    });

    test("returns content when getContent=true", async () => {
      const plugin = createPlugin();
      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getContent: true,
      });

      expect(result).toBe("AI-generated response content");
      expect(mockGetContent).toHaveBeenCalledTimes(1);
      expect(mockGetTokenUsage).not.toHaveBeenCalled();
      expect(mockGetFinishReason).not.toHaveBeenCalled();
    });

    test("returns token usage when getTokenUsage=true", async () => {
      const plugin = createPlugin();
      const result = await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        getTokenUsage: true,
      });

      expect(result).toEqual({ prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 });
      expect(mockGetTokenUsage).toHaveBeenCalledTimes(1);
      expect(mockGetContent).not.toHaveBeenCalled();
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
      expect(mockGetContent).not.toHaveBeenCalled();
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

      // switch(true) hits getContent first
      expect(result).toBe("AI-generated response content");
      expect(mockGetContent).toHaveBeenCalledTimes(1);
    });
  });

  describe("OrchestrationClient interaction", () => {
    test("creates OrchestrationClient with clientConfig", async () => {
      const plugin = createPlugin();
      await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(MockOrchestrationClient).toHaveBeenCalledTimes(1);
      expect(MockOrchestrationClient).toHaveBeenCalledWith(CLIENT_CONFIG);
    });

    test("calls chatCompletion with chatCompletionConfig", async () => {
      const plugin = createPlugin();
      await plugin.getHarmonizedChatCompletion({
        clientConfig: CLIENT_CONFIG,
        chatCompletionConfig: CHAT_COMPLETION_CONFIG,
      });

      expect(mockChatCompletion).toHaveBeenCalledTimes(1);
      expect(mockChatCompletion).toHaveBeenCalledWith(CHAT_COMPLETION_CONFIG);
    });
  });

  describe("error handling", () => {
    test("propagates OrchestrationClient errors", async () => {
      mockChatCompletion.mockRejectedValue(new Error("Orchestration service unavailable"));

      const plugin = createPlugin();
      await expect(
        plugin.getHarmonizedChatCompletion({
          clientConfig: CLIENT_CONFIG,
          chatCompletionConfig: CHAT_COMPLETION_CONFIG,
        })
      ).rejects.toThrow("Orchestration service unavailable");
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

// ════════════════════════════════════════════════════════════════════
// getContentFilters
// ════════════════════════════════════════════════════════════════════

describe("getContentFilters", () => {
  describe("azure type", () => {
    test("returns azure content safety filter", async () => {
      const filterConfig = { Hate: 2, Violence: 4, SelfHarm: 0, Sexual: 0 };

      const plugin = createPlugin();
      const result = await plugin.getContentFilters({
        type: "azure",
        config: filterConfig,
      });

      expect(mockBuildAzureContentSafetyFilter).toHaveBeenCalledWith(filterConfig);
      expect(result).toEqual({ type: "azure_content_safety", config: { Hate: 2, Violence: 2 } });
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
      await expect(plugin.getContentFilters({ type: "openai", config: {} })).rejects.toThrow(/Unsupported type openai/);
    });

    test("throws with helpful message mentioning azure", async () => {
      const plugin = createPlugin();
      await expect(plugin.getContentFilters({ type: "google", config: {} })).rejects.toThrow(
        /currently supported type is 'azure'/
      );
    });
  });

  describe("error handling", () => {
    test("propagates buildAzureContentSafetyFilter errors", async () => {
      mockBuildAzureContentSafetyFilter.mockImplementation(() => {
        throw new Error("Invalid filter config");
      });

      const plugin = createPlugin();
      await expect(plugin.getContentFilters({ type: "azure", config: {} })).rejects.toThrow("Invalid filter config");
    });
  });
});
