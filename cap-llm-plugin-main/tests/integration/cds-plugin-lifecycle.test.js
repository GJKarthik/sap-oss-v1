/**
 * Integration tests for the CDS plugin lifecycle.
 *
 * These tests verify the end-to-end flow:
 *   1. Plugin registration via cds.requires
 *   2. "served" event fires → entity scanning
 *   3. @anonymize detection → createAnonymizedView called
 *   4. CAPLLMPlugin service instantiation + getAnonymizedData
 *
 * All external dependencies (HANA, AI SDK) are mocked, but the
 * internal wiring between cds-plugin.ts, anonymization-helper.ts,
 * and cap-llm-plugin.ts is exercised as a connected unit.
 */

const mockCreateAnonymizedView = jest.fn();
const mockDbRun = jest.fn(() => Promise.resolve([]));

jest.mock("../../lib/anonymization-helper.js", () => ({
  createAnonymizedView: mockCreateAnonymizedView,
}));

// ── SDK mocks (needed by cap-llm-plugin) ─────────────────────────────
jest.mock("@sap-ai-sdk/orchestration", () => ({
  OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: jest.fn() })),
  OrchestrationClient: jest.fn().mockImplementation(() => ({ chatCompletion: jest.fn() })),
  buildAzureContentSafetyFilter: jest.fn(),
}));

// ── CDS mock with realistic service/entity structure ─────────────────
let servedCallback = null;

const mockLogWarn = jest.fn();
const mockCds = {
  db: { run: mockDbRun, kind: "hana" },
  connect: { to: jest.fn() },
  services: [],
  log: jest.fn(() => ({ debug: jest.fn(), info: jest.fn(), warn: mockLogWarn, error: jest.fn() })),
  env: { requires: {} },
  requires: { "cap-llm-plugin": true },
  Service: class MockService {
    async init() {}
  },
  once: jest.fn((event, cb) => {
    if (event === "served") {
      servedCallback = cb;
    }
  }),
};

jest.mock("@sap/cds", () => mockCds, { virtual: true });

// ── Fixture: realistic CDS entity structures ─────────────────────────

function makeAnonymizedEntity(serviceName, entityName, algorithm, elements) {
  return {
    name: `${serviceName}.${entityName}`,
    "@anonymize": algorithm,
    projection: true,
    elements,
  };
}

function makeDbService(schema) {
  return {
    name: "db",
    options: { credentials: { schema } },
    entities: [],
  };
}

function makeAppService(name, entities) {
  return { name, entities };
}

// ── Helpers ──────────────────────────────────────────────────────────

function loadPlugin() {
  jest.resetModules();
  jest.mock("@sap/cds", () => mockCds, { virtual: true });
  jest.mock("../../lib/anonymization-helper.js", () => ({
    createAnonymizedView: mockCreateAnonymizedView,
  }));
  jest.mock("@sap-ai-sdk/orchestration", () => ({
    OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({ embed: jest.fn() })),
    OrchestrationClient: jest.fn().mockImplementation(() => ({ chatCompletion: jest.fn() })),
    buildAzureContentSafetyFilter: jest.fn(),
  }));
  require("../../cds-plugin.js");
}

function createPlugin() {
  const CAPLLMPlugin = require("../../srv/cap-llm-plugin");
  return new CAPLLMPlugin();
}

// ═════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════

beforeEach(() => {
  jest.clearAllMocks();
  servedCallback = null;
  mockCds.db.kind = "hana";
  mockCds.requires = { "cap-llm-plugin": true };
  mockCds.services = [];
  mockDbRun.mockReset().mockResolvedValue([]);
  mockCreateAnonymizedView.mockReset();
});

describe("CDS plugin lifecycle — @anonymize integration", () => {
  describe("full lifecycle: register → scan → create view", () => {
    test("detects @anonymize entity and creates anonymized view on HANA", async () => {
      const entity = makeAnonymizedEntity("CustomerService", "Customers", "ALGORITHM 'K-ANONYMITY'", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
        NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
        EMAIL: { name: "EMAIL", "@anonymize": "K-ANONYMITY" },
        AGE: { name: "AGE" }, // not annotated — should be excluded
      });

      mockCds.services = [makeDbService("PROD_SCHEMA"), makeAppService("CustomerService", [entity])];

      loadPlugin();
      expect(servedCallback).toBeInstanceOf(Function);
      await servedCallback();

      expect(mockCreateAnonymizedView).toHaveBeenCalledTimes(1);
      expect(mockCreateAnonymizedView).toHaveBeenCalledWith(
        "PROD_SCHEMA",
        "CustomerService.Customers",
        "ALGORITHM 'K-ANONYMITY'",
        {
          ID: "is_sequence",
          NAME: "K-ANONYMITY",
          EMAIL: "K-ANONYMITY",
        }
      );
    });

    test("processes multiple annotated entities across services", async () => {
      const hrEntity = makeAnonymizedEntity("HRService", "Employees", "ALGORITHM 'L-DIVERSITY'", {
        EMP_ID: { name: "EMP_ID", "@anonymize": "is_sequence" },
        SALARY: { name: "SALARY", "@anonymize": "L-DIVERSITY" },
      });

      const salesEntity = makeAnonymizedEntity("SalesService", "Orders", "ALGORITHM 'K-ANONYMITY'", {
        ORDER_ID: { name: "ORDER_ID", "@anonymize": "is_sequence" },
        CUSTOMER_NAME: { name: "CUSTOMER_NAME", "@anonymize": "K-ANONYMITY" },
      });

      const plainEntity = {
        name: "SalesService.Products",
        "@anonymize": null,
        projection: true,
        elements: { PRODUCT_ID: { name: "PRODUCT_ID" } },
      };

      mockCds.services = [
        makeDbService("ENTERPRISE_SCHEMA"),
        makeAppService("HRService", [hrEntity]),
        makeAppService("SalesService", [salesEntity, plainEntity]),
      ];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).toHaveBeenCalledTimes(2);

      // First call: HR entity
      expect(mockCreateAnonymizedView).toHaveBeenCalledWith(
        "ENTERPRISE_SCHEMA",
        "HRService.Employees",
        "ALGORITHM 'L-DIVERSITY'",
        { EMP_ID: "is_sequence", SALARY: "L-DIVERSITY" }
      );

      // Second call: Sales entity
      expect(mockCreateAnonymizedView).toHaveBeenCalledWith(
        "ENTERPRISE_SCHEMA",
        "SalesService.Orders",
        "ALGORITHM 'K-ANONYMITY'",
        { ORDER_ID: "is_sequence", CUSTOMER_NAME: "K-ANONYMITY" }
      );
    });
  });

  describe("skipping conditions", () => {
    test("skips when db is not HANA", async () => {
      const entity = makeAnonymizedEntity("svc", "Ent", "ALGORITHM 'K-ANONYMITY'", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      mockCds.services = [makeDbService("S"), makeAppService("svc", [entity])];
      mockCds.db.kind = "sqlite";

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
      expect(mockLogWarn).toHaveBeenCalledWith(expect.stringContaining("only supported with SAP HANA Cloud"));
    });

    test("skips when schema cannot be resolved", async () => {
      const entity = makeAnonymizedEntity("svc", "Ent", "ALGORITHM 'K-ANONYMITY'", {
        ID: { name: "ID", "@anonymize": "is_sequence" },
      });

      mockCds.services = [{ name: "db", options: {}, entities: [] }, makeAppService("svc", [entity])];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
      expect(mockLogWarn).toHaveBeenCalledWith(expect.stringContaining("HANA schema name could not be resolved"));
    });

    test("does not register callback when plugin is not required", () => {
      mockCds.requires = {};
      loadPlugin();
      expect(servedCallback).toBeNull();
    });
  });
});

describe("CAPLLMPlugin.getAnonymizedData — integration", () => {
  test("queries the anonymized view and returns results", async () => {
    const mockRows = [
      { ID: 1, NAME: "John ***", EMAIL: "j***@example.com" },
      { ID: 2, NAME: "Jane ***", EMAIL: "j***@example.com" },
    ];
    mockDbRun.mockResolvedValue(mockRows);

    // Set up CDS services structure so getAnonymizedData can find the entity
    mockCds.services = {
      CustomerService: {
        entities: {
          Customers: {
            name: "Customers",
            elements: {
              ID: { name: "ID", "@anonymize": "is_sequence" },
              NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
              EMAIL: { name: "EMAIL", "@anonymize": "K-ANONYMITY" },
            },
          },
        },
      },
    };

    const plugin = createPlugin();
    const result = await plugin.getAnonymizedData("CustomerService.Customers");

    expect(result).toEqual(mockRows);
    expect(mockDbRun).toHaveBeenCalledTimes(1);
    expect(mockDbRun.mock.calls[0][0]).toBe('SELECT * FROM "CUSTOMERSERVICE_CUSTOMERS_ANOMYZ_V"');
  });

  test("queries with sequence IDs filter", async () => {
    const mockRows = [{ ID: 1, NAME: "John ***" }];
    mockDbRun.mockResolvedValue(mockRows);

    mockCds.services = {
      HRService: {
        entities: {
          Employees: {
            name: "Employees",
            elements: {
              EMP_ID: { name: "EMP_ID", "@anonymize": "is_sequence" },
              SALARY: { name: "SALARY", "@anonymize": "L-DIVERSITY" },
            },
          },
        },
      },
    };

    const plugin = createPlugin();
    const result = await plugin.getAnonymizedData("HRService.Employees", [1, 3, 5]);

    expect(result).toEqual(mockRows);
    expect(mockDbRun).toHaveBeenCalledWith(
      'SELECT * FROM "HRSERVICE_EMPLOYEES_ANOMYZ_V" WHERE "EMP_ID" IN (?, ?, ?)',
      [1, 3, 5]
    );
  });

  test("throws when entity is not found", async () => {
    mockCds.services = {};

    const plugin = createPlugin();
    await expect(plugin.getAnonymizedData("Missing.Entity")).rejects.toThrow(/Entity "Missing.Entity" not found/);
  });

  test("throws when sequence column is missing", async () => {
    mockCds.services = {
      svc: {
        entities: {
          Ent: {
            name: "Ent",
            elements: {
              FIELD: { name: "FIELD", "@anonymize": "K-ANONYMITY" }, // no is_sequence
            },
          },
        },
      },
    };

    const plugin = createPlugin();
    await expect(plugin.getAnonymizedData("svc.Ent")).rejects.toThrow(/Sequence column.*not found/);
  });

  test("end-to-end: plugin detects entity, then getAnonymizedData queries its view", async () => {
    // Step 1: Plugin registers and scans entities on "served"
    const entity = makeAnonymizedEntity("DataService", "Records", "ALGORITHM 'K-ANONYMITY'", {
      REC_ID: { name: "REC_ID", "@anonymize": "is_sequence" },
      CONTENT: { name: "CONTENT", "@anonymize": "K-ANONYMITY" },
    });

    mockCds.services = [makeDbService("APP_SCHEMA"), makeAppService("DataService", [entity])];

    loadPlugin();
    await servedCallback();

    // Verify view was created
    expect(mockCreateAnonymizedView).toHaveBeenCalledWith(
      "APP_SCHEMA",
      "DataService.Records",
      "ALGORITHM 'K-ANONYMITY'",
      { REC_ID: "is_sequence", CONTENT: "K-ANONYMITY" }
    );

    // Step 2: Now set up services map for getAnonymizedData
    mockCds.services = {
      DataService: {
        entities: {
          Records: {
            name: "Records",
            elements: {
              REC_ID: { name: "REC_ID", "@anonymize": "is_sequence" },
              CONTENT: { name: "CONTENT", "@anonymize": "K-ANONYMITY" },
            },
          },
        },
      },
    };

    const mockAnonymizedRows = [
      { REC_ID: 1, CONTENT: "***redacted***" },
      { REC_ID: 2, CONTENT: "***redacted***" },
    ];
    mockDbRun.mockResolvedValue(mockAnonymizedRows);

    // Step 3: Query anonymized data through the plugin
    const plugin = createPlugin();
    const result = await plugin.getAnonymizedData("DataService.Records");

    expect(result).toEqual(mockAnonymizedRows);
    expect(mockDbRun).toHaveBeenCalledWith('SELECT * FROM "DATASERVICE_RECORDS_ANOMYZ_V"');
  });
});
