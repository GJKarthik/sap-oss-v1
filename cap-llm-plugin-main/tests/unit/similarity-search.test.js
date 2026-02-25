const mockDbRun = jest.fn(() => Promise.resolve([]));
const mockDbConnect = jest.fn(() => Promise.resolve({ run: mockDbRun, send: jest.fn() }));

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

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: jest.fn() })),
  OrchestrationClient: jest.fn(),
  buildAzureContentSafetyFilter: jest.fn(),
}));

const CAPLLMPlugin = require("../../srv/cap-llm-plugin");

beforeEach(() => {
  jest.clearAllMocks();
  mockDbRun.mockReset().mockResolvedValue([]);
  mockDbConnect.mockReset().mockResolvedValue({ run: mockDbRun, send: jest.fn() });
});

function createPlugin() {
  return new CAPLLMPlugin();
}

const VALID_EMBEDDING = [0.1, 0.2, -0.3, 0.4, 0.5];

const MOCK_SEARCH_RESULTS = [
  { PAGE_CONTENT: "Document about AI", SCORE: 0.95 },
  { PAGE_CONTENT: "Document about ML", SCORE: 0.87 },
  { PAGE_CONTENT: "Document about NLP", SCORE: 0.81 },
];

describe("similaritySearch", () => {
  test("valid COSINE_SIMILARITY search returns results", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve(MOCK_SEARCH_RESULTS)) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    const result = await plugin.similaritySearch(
      "MY_TABLE",
      "EMBEDDING_COL",
      "CONTENT_COL",
      VALID_EMBEDDING,
      "COSINE_SIMILARITY",
      3
    );

    expect(result).toEqual(MOCK_SEARCH_RESULTS);
    expect(dbMock.run).toHaveBeenCalledTimes(1);

    const sql = dbMock.run.mock.calls[0][0];
    expect(sql).toContain("COSINE_SIMILARITY");
    expect(sql).toContain('FROM "MY_TABLE"');
    expect(sql).toContain('"EMBEDDING_COL"');
    expect(sql).toContain('"CONTENT_COL"');
    expect(sql).toContain("SELECT TOP 3");
    expect(sql).toContain("ORDER BY SCORE DESC");
  });

  test("valid L2DISTANCE search uses ASC ordering", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve(MOCK_SEARCH_RESULTS)) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    await plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "L2DISTANCE", 5);

    const sql = dbMock.run.mock.calls[0][0];
    expect(sql).toContain("L2DISTANCE");
    expect(sql).toContain("ORDER BY SCORE ASC");
    expect(sql).toContain("SELECT TOP 5");
  });

  test("embedding values are correctly serialized in SQL", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve([])) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    await plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", [1.0, -2.5, 3.0], "COSINE_SIMILARITY", 1);

    const sql = dbMock.run.mock.calls[0][0];
    expect(sql).toContain("TO_REAL_VECTOR('[1,-2.5,3]')");
  });

  test("rejects invalid algorithm name", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "INVALID_ALGO", 3)
    ).rejects.toThrow(/Invalid algorithm name: INVALID_ALGO/);
  });

  test("rejects tableName with SQL injection characters", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch(
        "table; DROP TABLE users --",
        "EMBEDDING_COL",
        "CONTENT_COL",
        VALID_EMBEDDING,
        "COSINE_SIMILARITY",
        3
      )
    ).rejects.toThrow(/Invalid tableName/);
  });

  test("rejects embeddingColumnName with SQL injection", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "col); DROP TABLE --", "CONTENT_COL", VALID_EMBEDDING, "COSINE_SIMILARITY", 3)
    ).rejects.toThrow(/Invalid embeddingColumnName/);
  });

  test("rejects contentColumn with SQL injection", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "col' OR '1'='1", VALID_EMBEDDING, "COSINE_SIMILARITY", 3)
    ).rejects.toThrow(/Invalid contentColumn/);
  });

  test("rejects non-integer topK", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch(
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        VALID_EMBEDDING,
        "COSINE_SIMILARITY",
        "3; DROP TABLE --"
      )
    ).rejects.toThrow(/Invalid topK/);
  });

  test("rejects topK of 0", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "COSINE_SIMILARITY", 0)
    ).rejects.toThrow(/Invalid topK/);
  });

  test("rejects negative topK", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "COSINE_SIMILARITY", -1)
    ).rejects.toThrow(/Invalid topK/);
  });

  test("rejects empty embedding array", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", [], "COSINE_SIMILARITY", 3)
    ).rejects.toThrow(/must be a non-empty array/);
  });

  test("rejects embedding with non-numeric values", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch(
        "MY_TABLE",
        "EMBEDDING_COL",
        "CONTENT_COL",
        [0.1, "malicious", 0.3],
        "COSINE_SIMILARITY",
        3
      )
    ).rejects.toThrow(/not a finite number/);
  });

  test("rejects embedding with NaN", async () => {
    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", [0.1, NaN], "COSINE_SIMILARITY", 3)
    ).rejects.toThrow(/not a finite number/);
  });

  test("returns undefined when db returns no results", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve(null)) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    const result = await plugin.similaritySearch(
      "MY_TABLE",
      "EMBEDDING_COL",
      "CONTENT_COL",
      VALID_EMBEDDING,
      "COSINE_SIMILARITY",
      3
    );

    expect(result).toBeUndefined();
  });

  test("returns empty array when db returns empty array", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve([])) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    const result = await plugin.similaritySearch(
      "MY_TABLE",
      "EMBEDDING_COL",
      "CONTENT_COL",
      VALID_EMBEDDING,
      "COSINE_SIMILARITY",
      3
    );

    // Empty array is truthy, so it gets returned
    expect(result).toEqual([]);
  });

  test("connects to 'db' service", async () => {
    const dbMock = { run: jest.fn(() => Promise.resolve(MOCK_SEARCH_RESULTS)) };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    await plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "COSINE_SIMILARITY", 3);

    expect(mockDbConnect).toHaveBeenCalledWith("db");
  });

  test("propagates db errors", async () => {
    const dbMock = {
      run: jest.fn(() => Promise.reject(new Error("HANA connection failed"))),
    };
    mockDbConnect.mockResolvedValue(dbMock);

    const plugin = createPlugin();
    await expect(
      plugin.similaritySearch("MY_TABLE", "EMBEDDING_COL", "CONTENT_COL", VALID_EMBEDDING, "COSINE_SIMILARITY", 3)
    ).rejects.toThrow("HANA connection failed");
  });
});
