/**
 * CDS mock utilities for unit testing cap-llm-plugin.
 *
 * Mocks the global `cds` object that the plugin depends on,
 * including `cds.db.run`, `cds.connect.to`, `cds.services`, and `cds.Service`.
 */

/**
 * Creates a fresh mock of the `cds` global with configurable behavior.
 *
 * @param {object} [options] - Configuration options.
 * @param {Function} [options.dbRunImpl] - Custom implementation for `cds.db.run`.
 * @param {object} [options.services] - Mock CDS services map.
 * @param {string} [options.dbKind] - The db kind (e.g., "hana", "sqlite"). Defaults to "hana".
 * @returns {object} The mocked cds object.
 */
function createCdsMock(options = {}) {
  const dbRunMock = jest.fn(options.dbRunImpl || (() => Promise.resolve([])));
  const connectToMock = jest.fn(() =>
    Promise.resolve({
      run: dbRunMock,
      send: jest.fn(() => Promise.resolve({})),
    })
  );

  const cdsMock = {
    db: {
      run: dbRunMock,
      kind: options.dbKind || "hana",
    },
    connect: {
      to: connectToMock,
    },
    services: options.services || {},
    env: {
      requires: options.envRequires || {},
    },
    requires: options.cdsRequires || {},
    Service: class MockService {
      async init() {}
    },
    once: jest.fn(),
  };

  return cdsMock;
}

/**
 * Installs the CDS mock as a global `cds` variable accessible via `require("@sap/cds")`.
 * Call this in `beforeEach` and clean up in `afterEach`.
 *
 * @param {object} cdsMock - The mock cds object from createCdsMock.
 */
function installCdsMock(cdsMock) {
  jest.mock("@sap/cds", () => cdsMock, { virtual: true });
  // Also set as global for files that use `cds` without require (like anonymization-helper.js)
  global.cds = cdsMock;
}

/**
 * Creates a mock CDS entity with optional @anonymize annotations.
 *
 * @param {string} name - Entity name.
 * @param {object} elements - Map of element name → element definition.
 * @returns {object} Mock entity object.
 */
function createMockEntity(name, elements = {}) {
  return {
    name,
    elements,
    "@anonymize": null,
    projection: true,
  };
}

module.exports = {
  createCdsMock,
  installCdsMock,
  createMockEntity,
};
