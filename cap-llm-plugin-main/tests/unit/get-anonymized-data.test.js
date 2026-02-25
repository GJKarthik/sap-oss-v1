const mockDbRun = jest.fn(() => Promise.resolve([]));

const mockCds = {
  db: { run: mockDbRun, kind: "hana" },
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

jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: jest.fn() })),
  OrchestrationClient: jest.fn(),
  buildAzureContentSafetyFilter: jest.fn(),
}));

const CAPLLMPlugin = require("../../srv/cap-llm-plugin");

function createPlugin() {
  return new CAPLLMPlugin();
}

/**
 * Helper to register a mock entity in the mock CDS services.
 */
function registerEntity(serviceName, entityName, elements, anonymize = null) {
  if (!mockCds.services[serviceName]) {
    mockCds.services[serviceName] = { entities: {} };
  }
  mockCds.services[serviceName].entities[entityName] = {
    name: entityName,
    elements,
    "@anonymize": anonymize,
    projection: true,
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  mockDbRun.mockReset().mockResolvedValue([]);
  // Reset services for each test
  mockCds.services = {};
});

describe("getAnonymizedData", () => {
  describe("valid inputs", () => {
    test("returns all rows when no sequenceIds provided", async () => {
      const mockRows = [
        { ID: 1, NAME: "***", AGE: 30 },
        { ID: 2, NAME: "***", AGE: 25 },
      ];
      mockDbRun.mockResolvedValue(mockRows);

      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
        NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
        AGE: { name: "AGE" },
      });

      const plugin = createPlugin();
      const result = await plugin.getAnonymizedData("myService.MyEntity");

      expect(result).toEqual(mockRows);
      expect(mockDbRun).toHaveBeenCalledTimes(1);

      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toBe('SELECT * FROM "MYSERVICE_MYENTITY_ANOMYZ_V"');
      // No params passed for the no-filter case
      expect(mockDbRun.mock.calls[0][1]).toBeUndefined();
    });

    test("returns filtered rows when sequenceIds are provided (numbers)", async () => {
      const mockRows = [{ ID: 1, NAME: "***", AGE: 30 }];
      mockDbRun.mockResolvedValue(mockRows);

      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
        NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
      });

      const plugin = createPlugin();
      const result = await plugin.getAnonymizedData("myService.MyEntity", [1, 2]);

      expect(result).toEqual(mockRows);
      expect(mockDbRun).toHaveBeenCalledTimes(1);

      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toBe('SELECT * FROM "MYSERVICE_MYENTITY_ANOMYZ_V" WHERE "ID" IN (?, ?)');
      // Parameterized values
      expect(mockDbRun.mock.calls[0][1]).toEqual([1, 2]);
    });

    test("returns filtered rows when sequenceIds are strings", async () => {
      mockDbRun.mockResolvedValue([]);

      registerEntity("myService", "MyEntity", {
        SEQ: { name: "SEQ", "@anonymize": "is_sequence" },
        DATA: { name: "DATA" },
      });

      const plugin = createPlugin();
      await plugin.getAnonymizedData("myService.MyEntity", ["abc", "def"]);

      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toContain('WHERE "SEQ" IN (?, ?)');
      expect(mockDbRun.mock.calls[0][1]).toEqual(["abc", "def"]);
    });

    test("returns empty array for empty sequenceIds (default)", async () => {
      mockDbRun.mockResolvedValue([]);

      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      const result = await plugin.getAnonymizedData("myService.MyEntity");

      expect(result).toEqual([]);
      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).not.toContain("WHERE");
    });

    test("correctly derives view name from dotted entity name", async () => {
      mockDbRun.mockResolvedValue([]);

      registerEntity("catalogService", "Products", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await plugin.getAnonymizedData("catalogService.Products");

      const sql = mockDbRun.mock.calls[0][0];
      expect(sql).toContain('"CATALOGSERVICE_PRODUCTS_ANOMYZ_V"');
    });
  });

  describe("entity not found", () => {
    test("throws when entity does not exist in CDS services", async () => {
      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("nonExistent.Entity")).rejects.toThrow(
        /Entity "nonExistent.Entity" not found in CDS services/
      );
      expect(mockDbRun).not.toHaveBeenCalled();
    });

    test("throws when service exists but entity does not", async () => {
      mockCds.services["myService"] = { entities: {} };

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.Missing")).rejects.toThrow(
        /Entity "myService.Missing" not found in CDS services/
      );
    });

    test("throws when entityName has no dot separator", async () => {
      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("noDotEntityName")).rejects.toThrow(/not found in CDS services/);
    });
  });

  describe("missing sequence column", () => {
    test("throws when no element has @anonymize with is_sequence", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID" },
        NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity")).rejects.toThrow(
        /Sequence column for entity "MyEntity" not found/
      );
    });

    test("throws when @anonymize exists but does not contain is_sequence", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "K-ANONYMITY" },
        NAME: { name: "NAME", "@anonymize": "L-DIVERSITY" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity")).rejects.toThrow(
        /Sequence column for entity "MyEntity" not found/
      );
    });
  });

  describe("sequenceIds validation", () => {
    test("rejects sequenceIds containing an object", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity", [1, { malicious: true }])).rejects.toThrow(
        /Invalid sequenceId at index 1: must be a string or number/
      );
    });

    test("rejects sequenceIds containing null", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity", [null])).rejects.toThrow(
        /Invalid sequenceId at index 0: must be a string or number/
      );
    });

    test("rejects sequenceIds containing an array", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity", [[1, 2]])).rejects.toThrow(
        /Invalid sequenceId at index 0: must be a string or number/
      );
    });

    test("rejects sequenceIds containing boolean", async () => {
      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await expect(plugin.getAnonymizedData("myService.MyEntity", [true])).rejects.toThrow(
        /Invalid sequenceId at index 0: must be a string or number/
      );
    });
  });

  describe("SQL injection prevention", () => {
    test("sequenceIds are parameterized, not interpolated", async () => {
      mockDbRun.mockResolvedValue([]);

      registerEntity("myService", "MyEntity", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      const plugin = createPlugin();
      await plugin.getAnonymizedData("myService.MyEntity", ["1' OR '1'='1", "2"]);

      const sql = mockDbRun.mock.calls[0][0];
      // The SQL should contain placeholders, NOT the actual values
      expect(sql).toContain("IN (?, ?)");
      expect(sql).not.toContain("OR");
      // Values should be passed as separate params
      expect(mockDbRun.mock.calls[0][1]).toEqual(["1' OR '1'='1", "2"]);
    });
  });
});
