// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const mockCreateAnonymizedView = jest.fn();

jest.mock("../../lib/anonymization-helper.js", () => ({
  createAnonymizedView: mockCreateAnonymizedView,
}));

// We need to test the cds-plugin.js module which runs code at require-time
// based on cds.requires and cds.once. We'll capture the 'served' callback
// and invoke it manually.

let servedCallback = null;

const mockLogWarn = jest.fn();
const mockCds = {
  db: { run: jest.fn(), kind: "hana" },
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

beforeEach(() => {
  jest.clearAllMocks();
  servedCallback = null;
  mockCds.db.kind = "hana";
  mockCds.requires = { "cap-llm-plugin": true };
  mockCds.services = [];
  mockCreateAnonymizedView.mockReset();
});

function loadPlugin() {
  jest.isolateModules(() => {
    jest.mock("@sap/cds", () => mockCds, { virtual: true });
    jest.mock("../../lib/anonymization-helper.js", () => ({
      createAnonymizedView: mockCreateAnonymizedView,
    }));
    require("../../cds-plugin.js");
  });
}

describe("cds-plugin.js", () => {
  describe("registration", () => {
    test("registers served callback when cap-llm-plugin is required", () => {
      loadPlugin();

      expect(mockCds.once).toHaveBeenCalledWith("served", expect.any(Function));
      expect(servedCallback).toBeInstanceOf(Function);
    });

    test("does not register served callback when cap-llm-plugin is not required", () => {
      mockCds.requires = {};
      loadPlugin();

      expect(servedCallback).toBeNull();
    });
  });

  describe("served callback — entity scanning", () => {
    test("calls createAnonymizedView for entity with @anonymize on HANA", async () => {
      const mockEntity = {
        name: "myService.MyEntity",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: true,
        elements: {
          ID: { name: "ID", "@anonymize": "is_sequence" },
          NAME: { name: "NAME", "@anonymize": "K-ANONYMITY" },
          AGE: { name: "AGE" },
        },
      };

      const dbService = {
        name: "db",
        options: { credentials: { schema: "MY_SCHEMA" } },
        entities: [],
      };

      const appService = {
        name: "myService",
        entities: [mockEntity],
      };

      mockCds.services = [dbService, appService];
      mockCds.db.kind = "hana";

      loadPlugin();
      expect(servedCallback).toBeInstanceOf(Function);
      await servedCallback();

      expect(mockCreateAnonymizedView).toHaveBeenCalledTimes(1);
      expect(mockCreateAnonymizedView).toHaveBeenCalledWith(
        "MY_SCHEMA",
        "myService.MyEntity",
        "ALGORITHM 'K-ANONYMITY'",
        { ID: "is_sequence", NAME: "K-ANONYMITY" }
      );
    });

    test("skips entities without @anonymize annotation", async () => {
      const mockEntity = {
        name: "myService.MyEntity",
        "@anonymize": null,
        projection: true,
        elements: {
          ID: { name: "ID" },
        },
      };

      mockCds.services = [
        { name: "db", options: { credentials: { schema: "S" } }, entities: [] },
        { name: "myService", entities: [mockEntity] },
      ];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
    });

    test("skips entities without projection", async () => {
      const mockEntity = {
        name: "myService.MyEntity",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: false,
        elements: {
          ID: { name: "ID", "@anonymize": "is_sequence" },
        },
      };

      mockCds.services = [
        { name: "db", options: { credentials: { schema: "S" } }, entities: [] },
        { name: "myService", entities: [mockEntity] },
      ];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
    });

    test("collects only elements with @anonymize annotation", async () => {
      const mockEntity = {
        name: "svc.Ent",
        "@anonymize": "ALGORITHM 'L-DIVERSITY'",
        projection: true,
        elements: {
          A: { name: "A", "@anonymize": "is_sequence" },
          B: { name: "B" }, // no annotation
          C: { name: "C", "@anonymize": "L-DIVERSITY" },
          D: { name: "D" }, // no annotation
        },
      };

      mockCds.services = [
        { name: "db", options: { credentials: { schema: "SCH" } }, entities: [] },
        { name: "svc", entities: [mockEntity] },
      ];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).toHaveBeenCalledWith("SCH", "svc.Ent", "ALGORITHM 'L-DIVERSITY'", {
        A: "is_sequence",
        C: "L-DIVERSITY",
      });
    });

    test("handles multiple entities across multiple services", async () => {
      const entity1 = {
        name: "svc1.E1",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: true,
        elements: { X: { name: "X", "@anonymize": "is_sequence" } },
      };
      const entity2 = {
        name: "svc2.E2",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: true,
        elements: { Y: { name: "Y", "@anonymize": "is_sequence" } },
      };
      const entity3 = {
        name: "svc2.E3",
        "@anonymize": null, // not annotated
        projection: true,
        elements: {},
      };

      mockCds.services = [
        { name: "db", options: { credentials: { schema: "SCH" } }, entities: [] },
        { name: "svc1", entities: [entity1] },
        { name: "svc2", entities: [entity2, entity3] },
      ];

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).toHaveBeenCalledTimes(2);
    });
  });

  describe("non-HANA database", () => {
    test("warns and skips when db kind is not hana", async () => {
      const mockEntity = {
        name: "svc.Ent",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: true,
        elements: { ID: { name: "ID", "@anonymize": "is_sequence" } },
      };

      mockCds.services = [
        { name: "db", options: { credentials: { schema: "S" } }, entities: [] },
        { name: "svc", entities: [mockEntity] },
      ];
      mockCds.db.kind = "sqlite";

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
      expect(mockLogWarn).toHaveBeenCalledWith(expect.stringContaining("only supported with SAP HANA Cloud"));
    });
  });

  describe("missing schemaName", () => {
    test("warns and skips when schemaName cannot be resolved", async () => {
      const mockEntity = {
        name: "svc.Ent",
        "@anonymize": "ALGORITHM 'K-ANONYMITY'",
        projection: true,
        elements: { ID: { name: "ID", "@anonymize": "is_sequence" } },
      };

      // db service exists but no credentials.schema
      mockCds.services = [
        { name: "db", options: {}, entities: [] },
        { name: "svc", entities: [mockEntity] },
      ];
      mockCds.db.kind = "hana";

      loadPlugin();
      await servedCallback();

      expect(mockCreateAnonymizedView).not.toHaveBeenCalled();
      expect(mockLogWarn).toHaveBeenCalledWith(expect.stringContaining("HANA schema name could not be resolved"));
    });
  });
});
