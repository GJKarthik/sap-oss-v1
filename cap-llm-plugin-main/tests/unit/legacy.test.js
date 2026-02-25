const mockSend = jest.fn();
const mockConnectTo = jest.fn(() => Promise.resolve({ run: jest.fn(), send: mockSend }));

const mockCds = {
  db: { run: jest.fn(), kind: "hana" },
  connect: { to: mockConnectTo },
  services: {},
  log: jest.fn(() => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() })),
  env: {
    requires: {
      GENERATIVE_AI_HUB: {
        EMBEDDING_MODEL_DESTINATION_NAME: "aicore-dest",
        EMBEDDING_MODEL_DEPLOYMENT_URL: "/v2/deployments/emb",
        EMBEDDING_MODEL_RESOURCE_GROUP: "default",
        EMBEDDING_MODEL_API_VERSION: "2024-02-01",
        CHAT_MODEL_DESTINATION_NAME: "aicore-dest",
        CHAT_MODEL_DEPLOYMENT_URL: "/v2/deployments/chat",
        CHAT_MODEL_RESOURCE_GROUP: "default",
        CHAT_MODEL_API_VERSION: "2024-02-01",
      },
    },
  },
  requires: {},
  Service: class MockService {
    async init() {}
  },
  once: jest.fn(),
};

jest.mock("@sap/cds", () => mockCds, { virtual: true });

const legacy = require("../../srv/legacy");

beforeEach(() => {
  jest.clearAllMocks();
  mockSend.mockReset();
  mockConnectTo.mockReset().mockResolvedValue({ run: jest.fn(), send: mockSend });
});

// ════════════════════════════════════════════════════════════════════
// getEmbedding (legacy)
// ════════════════════════════════════════════════════════════════════

describe("legacy.getEmbedding", () => {
  test("calls destination with correct URL and returns embedding", async () => {
    const mockResponse = {
      data: [{ embedding: [0.1, 0.2, 0.3], index: 0, object: "embedding" }],
    };
    mockSend.mockResolvedValue(mockResponse);

    const result = await legacy.getEmbedding("Hello");

    expect(result).toEqual([0.1, 0.2, 0.3]);
    expect(mockConnectTo).toHaveBeenCalledWith("aicore-dest");
    const sendArgs = mockSend.mock.calls[0][0];
    expect(sendArgs.query).toContain("/v2/deployments/emb/embeddings");
    expect(sendArgs.query).toContain("api-version=2024-02-01");
    expect(sendArgs.data).toEqual({ input: "Hello" });
    expect(sendArgs.headers["AI-Resource-Group"]).toBe("default");
  });

  test("throws on empty response", async () => {
    mockSend.mockResolvedValue(null);

    await expect(legacy.getEmbedding("test")).rejects.toThrow(/Empty response/);
  });

  test("throws on response without data", async () => {
    mockSend.mockResolvedValue({});

    await expect(legacy.getEmbedding("test")).rejects.toThrow(/Empty response/);
  });

  test("logs deprecation warning", async () => {
    const warnSpy = jest.spyOn(console, "warn").mockImplementation();
    mockSend.mockResolvedValue({ data: [{ embedding: [1] }] });

    await legacy.getEmbedding("test");

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("[DEPRECATED]"));
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("getEmbeddingWithConfig"));
    warnSpy.mockRestore();
  });

  test("propagates destination errors", async () => {
    mockSend.mockRejectedValue(new Error("Connection refused"));

    await expect(legacy.getEmbedding("test")).rejects.toThrow("Connection refused");
  });
});

// ════════════════════════════════════════════════════════════════════
// getChatCompletion (legacy)
// ════════════════════════════════════════════════════════════════════

describe("legacy.getChatCompletion", () => {
  const PAYLOAD = { messages: [{ role: "user", content: "Hi" }] };

  test("calls destination with correct URL and returns message", async () => {
    const mockResponse = {
      choices: [{ message: { role: "assistant", content: "Hello!" } }],
    };
    mockSend.mockResolvedValue(mockResponse);

    const result = await legacy.getChatCompletion(PAYLOAD);

    expect(result).toEqual({ role: "assistant", content: "Hello!" });
    expect(mockConnectTo).toHaveBeenCalledWith("aicore-dest");
    const sendArgs = mockSend.mock.calls[0][0];
    expect(sendArgs.query).toContain("/v2/deployments/chat/chat/completions");
    expect(sendArgs.query).toContain("api-version=2024-02-01");
    expect(sendArgs.data).toEqual(PAYLOAD);
  });

  test("throws on empty response", async () => {
    mockSend.mockResolvedValue(null);

    await expect(legacy.getChatCompletion(PAYLOAD)).rejects.toThrow(/Empty response/);
  });

  test("throws on response without choices", async () => {
    mockSend.mockResolvedValue({});

    await expect(legacy.getChatCompletion(PAYLOAD)).rejects.toThrow(/Empty response/);
  });

  test("logs deprecation warning", async () => {
    const warnSpy = jest.spyOn(console, "warn").mockImplementation();
    mockSend.mockResolvedValue({ choices: [{ message: { content: "ok" } }] });

    await legacy.getChatCompletion(PAYLOAD);

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("[DEPRECATED]"));
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("getChatCompletionWithConfig"));
    warnSpy.mockRestore();
  });

  test("propagates destination errors", async () => {
    mockSend.mockRejectedValue(new Error("Timeout"));

    await expect(legacy.getChatCompletion(PAYLOAD)).rejects.toThrow("Timeout");
  });
});

// ════════════════════════════════════════════════════════════════════
// getRagResponse (legacy)
// ════════════════════════════════════════════════════════════════════

describe("legacy.getRagResponse", () => {
  const mockGetEmbedding = jest.fn().mockResolvedValue([0.1, 0.2, 0.3]);
  const mockSimilaritySearch = jest.fn().mockResolvedValue([
    { PAGE_CONTENT: "Content A", SCORE: 0.9 },
    { PAGE_CONTENT: "Content B", SCORE: 0.8 },
  ]);
  const mockGetChatCompletion = jest.fn().mockResolvedValue({
    role: "assistant",
    content: "Answer based on context",
  });

  beforeEach(() => {
    mockGetEmbedding.mockClear().mockResolvedValue([0.1, 0.2, 0.3]);
    mockSimilaritySearch.mockClear().mockResolvedValue([
      { PAGE_CONTENT: "Content A", SCORE: 0.9 },
      { PAGE_CONTENT: "Content B", SCORE: 0.8 },
    ]);
    mockGetChatCompletion.mockClear().mockResolvedValue({
      role: "assistant",
      content: "Answer",
    });
  });

  test("returns completion and additionalContents", async () => {
    const result = await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "What is HANA?",
      "MY_TABLE",
      "EMB_COL",
      "CONTENT_COL",
      "Answer based on context.",
      undefined,
      3,
      "COSINE_SIMILARITY",
      undefined
    );

    expect(result.completion).toEqual({ role: "assistant", content: "Answer" });
    expect(result.additionalContents).toEqual([
      { score: 0.9, pageContent: "Content A" },
      { score: 0.8, pageContent: "Content B" },
    ]);
  });

  test("calls getEmbedding with user input", async () => {
    await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "Query",
      "T",
      "E",
      "C",
      "Inst"
    );

    expect(mockGetEmbedding).toHaveBeenCalledWith("Query");
  });

  test("calls similaritySearch with embedding result", async () => {
    await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "Query",
      "MY_TABLE",
      "EMB",
      "CONT",
      "Inst",
      undefined,
      5,
      "L2DISTANCE"
    );

    expect(mockSimilaritySearch).toHaveBeenCalledWith("MY_TABLE", "EMB", "CONT", [0.1, 0.2, 0.3], "L2DISTANCE", 5);
  });

  test("passes context into chat payload", async () => {
    const context = [
      { role: "user", content: "prev Q" },
      { role: "assistant", content: "prev A" },
    ];

    await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "Follow-up",
      "T",
      "E",
      "C",
      "Inst",
      context
    );

    const chatPayload = mockGetChatCompletion.mock.calls[0][0];
    expect(chatPayload.messages).toContainEqual({ role: "user", content: "prev Q" });
    expect(chatPayload.messages).toContainEqual({ role: "assistant", content: "prev A" });
  });

  test("merges chatParams into payload", async () => {
    const chatParams = { temperature: 0.5 };

    await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "Q",
      "T",
      "E",
      "C",
      "Inst",
      undefined,
      3,
      "COSINE_SIMILARITY",
      chatParams
    );

    const chatPayload = mockGetChatCompletion.mock.calls[0][0];
    expect(chatPayload.temperature).toBe(0.5);
  });

  test("logs deprecation warning", async () => {
    const warnSpy = jest.spyOn(console, "warn").mockImplementation();

    await legacy.getRagResponse(
      mockGetEmbedding,
      mockSimilaritySearch,
      mockGetChatCompletion,
      "Q",
      "T",
      "E",
      "C",
      "Inst"
    );

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("[DEPRECATED]"));
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("getRagResponseWithConfig"));
    warnSpy.mockRestore();
  });

  test("propagates embedding errors", async () => {
    mockGetEmbedding.mockRejectedValue(new Error("Embed fail"));

    await expect(
      legacy.getRagResponse(mockGetEmbedding, mockSimilaritySearch, mockGetChatCompletion, "Q", "T", "E", "C", "Inst")
    ).rejects.toThrow("Embed fail");
  });

  test("propagates similarity search errors", async () => {
    mockSimilaritySearch.mockRejectedValue(new Error("Search fail"));

    await expect(
      legacy.getRagResponse(mockGetEmbedding, mockSimilaritySearch, mockGetChatCompletion, "Q", "T", "E", "C", "Inst")
    ).rejects.toThrow("Search fail");
  });
});
