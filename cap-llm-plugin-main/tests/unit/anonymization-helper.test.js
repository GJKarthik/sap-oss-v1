const mockDbRun = jest.fn();

const mockCds = {
  db: { run: mockDbRun, kind: "hana" },
  log: jest.fn(() => ({ debug: jest.fn(), info: jest.fn(), warn: jest.fn(), error: jest.fn() })),
};

// Make cds available globally (anonymization-helper uses global cds)
global.cds = mockCds;

jest.mock("@sap/cds", () => mockCds, { virtual: true });

const { createAnonymizedView } = require("../../lib/anonymization-helper");

beforeEach(() => {
  jest.clearAllMocks();
  mockDbRun.mockReset();
  // Default: view does not exist
  mockDbRun.mockResolvedValue([{ count: 0 }]);
});

// ════════════════════════════════════════════════════════════════════
// createAnonymizedView — happy paths
// ════════════════════════════════════════════════════════════════════

describe("createAnonymizedView", () => {
  const SCHEMA = "MY_SCHEMA";
  const ENTITY = "myService.MyEntity";
  const ALGORITHM = "ALGORITHM 'K-ANONYMITY'";
  const ELEMENTS = {
    NAME: "K-ANONYMITY",
    ID: "is_sequence",
  };

  describe("happy path — view does not exist", () => {
    test("creates and refreshes anonymized view", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }]) // view existence check
        .mockResolvedValueOnce(undefined) // CREATE VIEW
        .mockResolvedValueOnce(undefined); // REFRESH VIEW

      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS);

      expect(mockDbRun).toHaveBeenCalledTimes(3);
    });

    test("checks view existence with parameterized query", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }])
        .mockResolvedValueOnce(undefined)
        .mockResolvedValueOnce(undefined);

      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS);

      const existenceCall = mockDbRun.mock.calls[0];
      expect(existenceCall[0]).toContain("SYS.VIEWS");
      expect(existenceCall[0]).toContain("VIEW_NAME = ?");
      expect(existenceCall[0]).toContain("SCHEMA_NAME = ?");
      expect(existenceCall[1]).toEqual(["MYSERVICE_MYENTITY_ANOMYZ_V", "MY_SCHEMA"]);
    });

    test("constructs CREATE VIEW with correct view name and columns", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }])
        .mockResolvedValueOnce(undefined)
        .mockResolvedValueOnce(undefined);

      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS);

      const createCall = mockDbRun.mock.calls[1][0];
      expect(createCall).toContain('CREATE VIEW "MYSERVICE_MYENTITY_ANOMYZ_V"');
      expect(createCall).toContain('"NAME"');
      expect(createCall).toContain('"ID"');
      expect(createCall).toContain('FROM "MYSERVICE_MYENTITY"');
      expect(createCall).toContain("WITH ANONYMIZATION");
      expect(createCall).toContain(ALGORITHM);
    });

    test("constructs REFRESH VIEW with correct view name", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }])
        .mockResolvedValueOnce(undefined)
        .mockResolvedValueOnce(undefined);

      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS);

      const refreshCall = mockDbRun.mock.calls[2][0];
      expect(refreshCall).toBe('REFRESH VIEW "MYSERVICE_MYENTITY_ANOMYZ_V" ANONYMIZATION');
    });

    test("escapes single quotes in annotation values", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }])
        .mockResolvedValueOnce(undefined)
        .mockResolvedValueOnce(undefined);

      const elements = { NAME: "O'Brien's data" };
      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, elements);

      const createCall = mockDbRun.mock.calls[1][0];
      expect(createCall).toContain("O''Brien''s data");
      expect(createCall).not.toContain("O'Brien");
    });
  });

  describe("happy path — view already exists", () => {
    test("drops existing view before creating new one", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 1 }]) // view exists
        .mockResolvedValueOnce(undefined) // DROP VIEW
        .mockResolvedValueOnce(undefined) // CREATE VIEW
        .mockResolvedValueOnce(undefined); // REFRESH VIEW

      await createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS);

      expect(mockDbRun).toHaveBeenCalledTimes(4);
      const dropCall = mockDbRun.mock.calls[1][0];
      expect(dropCall).toBe('DROP VIEW "MYSERVICE_MYENTITY_ANOMYZ_V"');
    });
  });

  describe("algorithm validation", () => {
    test("accepts K-ANONYMITY algorithm", async () => {
      mockDbRun.mockResolvedValue([{ count: 0 }]);

      await expect(createAnonymizedView(SCHEMA, ENTITY, "ALGORITHM 'K-ANONYMITY'", ELEMENTS)).resolves.toBeUndefined();
    });

    test("accepts L-DIVERSITY algorithm", async () => {
      mockDbRun.mockResolvedValue([{ count: 0 }]);

      await expect(createAnonymizedView(SCHEMA, ENTITY, "ALGORITHM 'L-DIVERSITY'", ELEMENTS)).resolves.toBeUndefined();
    });

    test("accepts DIFFERENTIAL_PRIVACY algorithm", async () => {
      mockDbRun.mockResolvedValue([{ count: 0 }]);

      await expect(
        createAnonymizedView(SCHEMA, ENTITY, "ALGORITHM 'DIFFERENTIAL_PRIVACY'", ELEMENTS)
      ).resolves.toBeUndefined();
    });

    test("rejects unknown algorithm", async () => {
      await expect(createAnonymizedView(SCHEMA, ENTITY, "ALGORITHM 'EVIL_INJECTION'", ELEMENTS)).rejects.toThrow(
        /Invalid anonymization algorithm/
      );
    });

    test("rejects empty algorithm string", async () => {
      await expect(createAnonymizedView(SCHEMA, ENTITY, "", ELEMENTS)).rejects.toThrow(/must be a non-empty string/);
    });

    test("rejects non-string algorithm", async () => {
      await expect(createAnonymizedView(SCHEMA, ENTITY, 42, ELEMENTS)).rejects.toThrow(/must be a non-empty string/);
    });
  });

  describe("identifier validation", () => {
    test("rejects schemaName with SQL injection", async () => {
      await expect(createAnonymizedView("MY_SCHEMA; DROP TABLE", ENTITY, ALGORITHM, ELEMENTS)).rejects.toThrow(
        /schemaName/
      );
    });

    test("rejects empty schemaName", async () => {
      await expect(createAnonymizedView("", ENTITY, ALGORITHM, ELEMENTS)).rejects.toThrow(/schemaName/);
    });

    test("rejects column name with injection characters", async () => {
      const badElements = { "NAME; DROP TABLE users--": "K-ANONYMITY" };
      await expect(createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, badElements)).rejects.toThrow(
        /anonymizedElement column/
      );
    });
  });

  describe("error handling", () => {
    test("throws when DROP VIEW fails", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 1 }]) // view exists
        .mockRejectedValueOnce(new Error("DROP failed")); // DROP fails

      await expect(createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS)).rejects.toThrow("DROP failed");
    });

    test("throws when CREATE VIEW fails", async () => {
      mockDbRun.mockResolvedValueOnce([{ count: 0 }]).mockRejectedValueOnce(new Error("CREATE failed"));

      await expect(createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS)).rejects.toThrow("CREATE failed");
    });

    test("throws when REFRESH VIEW fails", async () => {
      mockDbRun
        .mockResolvedValueOnce([{ count: 0 }])
        .mockResolvedValueOnce(undefined) // CREATE succeeds
        .mockRejectedValueOnce(new Error("REFRESH failed"));

      await expect(createAnonymizedView(SCHEMA, ENTITY, ALGORITHM, ELEMENTS)).rejects.toThrow("REFRESH failed");
    });
  });
});
