/**
 * Integration tests verifying that typed errors are thrown with
 * correct class, code, message, and details.
 *
 * Tests cover:
 *   - AnonymizationError (entity not found, missing sequence column, invalid sequence ID)
 *   - EmbeddingError (config validation, SDK request failure)
 *   - ChatCompletionError (config validation, SDK request failure, unsupported filter type, SDK filter failure)
 *   - ChatCompletionError via getHarmonizedChatCompletion (SDK failure wrapping)
 *   - CAPLLMPluginError base class inheritance
 */

const { AnonymizationError } = require("../../src/errors/AnonymizationError");
const { EmbeddingError } = require("../../src/errors/EmbeddingError");
const { ChatCompletionError } = require("../../src/errors/ChatCompletionError");
const { CAPLLMPluginError } = require("../../src/errors/CAPLLMPluginError");

// ── SDK mocks ────────────────────────────────────────────────────────
const mockEmbed = jest.fn();
const mockChatCompletion = jest.fn();
const mockBuildFilter = jest.fn();

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: mockEmbed })),
  OrchestrationClient: jest.fn().mockImplementation(() => ({ chatCompletion: mockChatCompletion })),
  buildAzureContentSafetyFilter: mockBuildFilter,
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

const VALID_EMBEDDING_CONFIG = {
  modelName: "text-embedding-ada-002",
  resourceGroup: "default",
  destinationName: "x",
  deploymentUrl: "x",
};
const VALID_CHAT_CONFIG = { modelName: "gpt-4o", resourceGroup: "default", destinationName: "x", deploymentUrl: "x" };

beforeEach(() => {
  jest.clearAllMocks();
  mockEmbed.mockResolvedValue({ getEmbeddings: () => [{ embedding: [0.1] }] });
  mockChatCompletion.mockResolvedValue({
    getContent: () => "ok",
    getTokenUsage: () => ({}),
    getFinishReason: () => "stop",
  });
  mockBuildFilter.mockReturnValue({ type: "azure_content_safety" });
  mockCds.services = {};
});

// ═════════════════════════════════════════════════════════════════════
// AnonymizationError
// ═════════════════════════════════════════════════════════════════════

describe("AnonymizationError", () => {
  test("ENTITY_NOT_FOUND: correct type, code, and details", async () => {
    expect.assertions(7);
    mockCds.services = {};
    const plugin = createPlugin();

    try {
      await plugin.getAnonymizedData("Missing.Entity");
    } catch (e) {
      expect(e).toBeInstanceOf(AnonymizationError);
      expect(e).toBeInstanceOf(CAPLLMPluginError);
      expect(e).toBeInstanceOf(Error);
      expect(e.code).toBe("ENTITY_NOT_FOUND");
      expect(e.details).toEqual({ entityName: "Missing.Entity" });
      expect(e.name).toBe("AnonymizationError");
      expect(e.message).toContain("Missing.Entity");
    }
  });

  test("SEQUENCE_COLUMN_NOT_FOUND: correct type, code, and details", async () => {
    expect.assertions(3);
    mockCds.services = {
      svc: { entities: { Ent: { name: "Ent", elements: { FIELD: { name: "FIELD", "@anonymize": "K-ANONYMITY" } } } } },
    };
    const plugin = createPlugin();

    try {
      await plugin.getAnonymizedData("svc.Ent");
    } catch (e) {
      expect(e).toBeInstanceOf(AnonymizationError);
      expect(e.code).toBe("SEQUENCE_COLUMN_NOT_FOUND");
      expect(e.details).toEqual({ entityName: "Ent" });
    }
  });

  test("INVALID_SEQUENCE_ID: correct type, code, and details", async () => {
    expect.assertions(3);
    mockCds.services = {
      svc: {
        entities: {
          Ent: {
            name: "Ent",
            elements: { ID: { name: "ID", "@anonymize": "is_sequence" } },
          },
        },
      },
    };
    const plugin = createPlugin();

    try {
      await plugin.getAnonymizedData("svc.Ent", [1, true]);
    } catch (e) {
      expect(e).toBeInstanceOf(AnonymizationError);
      expect(e.code).toBe("INVALID_SEQUENCE_ID");
      expect(e.details).toEqual({ index: 1, receivedType: "boolean" });
    }
  });
});

// ═════════════════════════════════════════════════════════════════════
// EmbeddingError
// ═════════════════════════════════════════════════════════════════════

describe("EmbeddingError", () => {
  test("EMBEDDING_CONFIG_INVALID for missing modelName", async () => {
    expect.assertions(4);
    const plugin = createPlugin();
    const badConfig = { ...VALID_EMBEDDING_CONFIG, modelName: "" };

    try {
      await plugin.getEmbeddingWithConfig(badConfig, "test");
    } catch (e) {
      expect(e).toBeInstanceOf(EmbeddingError);
      expect(e).toBeInstanceOf(CAPLLMPluginError);
      expect(e.code).toBe("EMBEDDING_CONFIG_INVALID");
      expect(e.details).toEqual({ missingField: "modelName" });
    }
  });

  test("EMBEDDING_CONFIG_INVALID for missing resourceGroup", async () => {
    expect.assertions(3);
    const plugin = createPlugin();
    const badConfig = { ...VALID_EMBEDDING_CONFIG, resourceGroup: "" };

    try {
      await plugin.getEmbeddingWithConfig(badConfig, "test");
    } catch (e) {
      expect(e).toBeInstanceOf(EmbeddingError);
      expect(e.code).toBe("EMBEDDING_CONFIG_INVALID");
      expect(e.details).toEqual({ missingField: "resourceGroup" });
    }
  });

  test("EMBEDDING_REQUEST_FAILED wraps SDK errors", async () => {
    expect.assertions(6);
    mockEmbed.mockRejectedValue(new Error("SDK timeout"));
    const plugin = createPlugin();

    try {
      await plugin.getEmbeddingWithConfig(VALID_EMBEDDING_CONFIG, "test");
    } catch (e) {
      expect(e).toBeInstanceOf(EmbeddingError);
      expect(e.code).toBe("EMBEDDING_REQUEST_FAILED");
      expect(e.message).toContain("SDK timeout");
      expect(e.details.modelName).toBe("text-embedding-ada-002");
      expect(e.details.resourceGroup).toBe("default");
      expect(e.details.cause).toBe("SDK timeout");
    }
  });
});

// ═════════════════════════════════════════════════════════════════════
// ChatCompletionError
// ═════════════════════════════════════════════════════════════════════

describe("ChatCompletionError", () => {
  test("CHAT_CONFIG_INVALID for missing modelName", async () => {
    expect.assertions(4);
    const plugin = createPlugin();
    const badConfig = { ...VALID_CHAT_CONFIG, modelName: "" };

    try {
      await plugin.getChatCompletionWithConfig(badConfig, { messages: [] });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e).toBeInstanceOf(CAPLLMPluginError);
      expect(e.code).toBe("CHAT_CONFIG_INVALID");
      expect(e.details).toEqual({ missingField: "modelName" });
    }
  });

  test("CHAT_CONFIG_INVALID for missing resourceGroup", async () => {
    expect.assertions(3);
    const plugin = createPlugin();
    const badConfig = { ...VALID_CHAT_CONFIG, resourceGroup: "" };

    try {
      await plugin.getChatCompletionWithConfig(badConfig, { messages: [] });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e.code).toBe("CHAT_CONFIG_INVALID");
      expect(e.details).toEqual({ missingField: "resourceGroup" });
    }
  });

  test("CHAT_COMPLETION_REQUEST_FAILED wraps SDK errors", async () => {
    expect.assertions(5);
    mockChatCompletion.mockRejectedValue(new Error("Rate limit exceeded"));
    const plugin = createPlugin();

    try {
      await plugin.getChatCompletionWithConfig(VALID_CHAT_CONFIG, { messages: [] });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e.code).toBe("CHAT_COMPLETION_REQUEST_FAILED");
      expect(e.message).toContain("Rate limit exceeded");
      expect(e.details.modelName).toBe("gpt-4o");
      expect(e.details.cause).toBe("Rate limit exceeded");
    }
  });

  test("UNSUPPORTED_FILTER_TYPE for non-azure type", async () => {
    expect.assertions(3);
    const plugin = createPlugin();

    try {
      await plugin.getContentFilters({ type: "google", config: {} });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e.code).toBe("UNSUPPORTED_FILTER_TYPE");
      expect(e.details).toEqual({ type: "google", supportedTypes: ["azure"] });
    }
  });

  test("CONTENT_FILTER_FAILED wraps SDK filter errors", async () => {
    expect.assertions(5);
    mockBuildFilter.mockImplementation(() => {
      throw new Error("Invalid filter config");
    });
    const plugin = createPlugin();

    try {
      await plugin.getContentFilters({ type: "azure", config: {} });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e.code).toBe("CONTENT_FILTER_FAILED");
      expect(e.message).toContain("Invalid filter config");
      expect(e.details.type).toBe("azure");
      expect(e.details.cause).toBe("Invalid filter config");
    }
  });

  test("HARMONIZED_CHAT_FAILED wraps OrchestrationClient errors", async () => {
    expect.assertions(4);
    mockChatCompletion.mockRejectedValue(new Error("Model not found"));
    const plugin = createPlugin();

    try {
      await plugin.getHarmonizedChatCompletion({
        clientConfig: { promptTemplating: { model: { name: "gpt-4o" } } },
        chatCompletionConfig: { messages: [{ role: "user", content: "test" }] },
      });
    } catch (e) {
      expect(e).toBeInstanceOf(ChatCompletionError);
      expect(e.code).toBe("HARMONIZED_CHAT_FAILED");
      expect(e.message).toContain("Model not found");
      expect(e.details.cause).toBe("Model not found");
    }
  });
});

// ═════════════════════════════════════════════════════════════════════
// CAPLLMPluginError base class
// ═════════════════════════════════════════════════════════════════════

describe("CAPLLMPluginError base class", () => {
  test("all typed errors extend CAPLLMPluginError and Error", () => {
    const anon = new AnonymizationError("test", "CODE");
    const emb = new EmbeddingError("test", "CODE");
    const chat = new ChatCompletionError("test", "CODE");

    for (const err of [anon, emb, chat]) {
      expect(err).toBeInstanceOf(CAPLLMPluginError);
      expect(err).toBeInstanceOf(Error);
      expect(err.code).toBe("CODE");
      expect(err.message).toBe("test");
    }
  });

  test("details is optional and defaults to undefined", () => {
    const err = new CAPLLMPluginError("msg", "CODE");
    expect(err.details).toBeUndefined();
  });

  test("details can contain arbitrary context", () => {
    const err = new CAPLLMPluginError("msg", "CODE", { foo: "bar", count: 42 });
    expect(err.details).toEqual({ foo: "bar", count: 42 });
  });

  test("has correct stack trace", () => {
    const err = new EmbeddingError("stack test", "STACK");
    expect(err.stack).toContain("stack test");
    expect(err.stack).toContain("typed-errors.test.js");
  });
});
