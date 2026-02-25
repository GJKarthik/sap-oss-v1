/**
 * E2E Test Helper — Plugin Setup
 *
 * Creates a fully wired CAPLLMPlugin instance with mocked CDS and SDK
 * dependencies for end-to-end pipeline testing.
 */

const {
  createEmbeddingResponse,
  createChatCompletionResponse,
  createContentFilter,
  createSimilaritySearchRows,
} = require("./mock-ai-core");

/**
 * Set up mocks and load the plugin for E2E testing.
 *
 * @param {object} overrides - Optional overrides for mock behavior.
 * @param {Function} overrides.dbRun - Custom mock for cds.db.run
 * @param {Function} overrides.embed - Custom mock for OrchestrationEmbeddingClient.embed
 * @param {Function} overrides.chatCompletion - Custom mock for OrchestrationClient.chatCompletion
 * @param {Function} overrides.buildFilter - Custom mock for buildAzureContentSafetyFilter
 * @returns {{ plugin: object, mocks: object }}
 */
function setupPlugin(overrides = {}) {
  // Clear module cache for fresh load
  jest.resetModules();

  // ── Mock DB ────────────────────────────────────────────────────────
  const mockDbRun = overrides.dbRun || jest.fn().mockResolvedValue(createSimilaritySearchRows());

  // ── Mock CDS ───────────────────────────────────────────────────────
  const mockLogWarn = jest.fn();
  const mockLogError = jest.fn();
  const mockLogDebug = jest.fn();
  const mockLogInfo = jest.fn();

  const mockCds = {
    db: { run: mockDbRun, kind: "hana" },
    connect: { to: jest.fn().mockResolvedValue({ run: mockDbRun }) },
    services: {
      TestService: {
        entities: {
          TestEntity: {
            name: "TestService.TestEntity",
            elements: {
              ID: { type: "cds.Integer", key: true },
              EMBEDDING: { type: "cds.Vector" },
              TEXT_CONTENT: { type: "cds.String" },
              SEQUENCE_ID: { type: "cds.String" },
            },
          },
        },
      },
    },
    log: jest.fn(() => ({
      debug: mockLogDebug,
      info: mockLogInfo,
      warn: mockLogWarn,
      error: mockLogError,
    })),
    Service: class MockService {
      async init() {}
    },
    once: jest.fn(),
    env: { requires: {} },
    requires: {},
  };

  jest.doMock("@sap/cds", () => mockCds);

  // ── Mock SDK ───────────────────────────────────────────────────────
  const mockEmbed = overrides.embed || jest.fn().mockResolvedValue(createEmbeddingResponse());
  const mockChatCompletion = overrides.chatCompletion || jest.fn().mockResolvedValue(createChatCompletionResponse());
  const mockBuildFilter = overrides.buildFilter || jest.fn().mockReturnValue(createContentFilter());

  jest.doMock("@sap-ai-sdk/orchestration", () => ({
    OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({
      embed: mockEmbed,
    })),
    OrchestrationClient: jest.fn().mockImplementation(() => ({
      chatCompletion: mockChatCompletion,
    })),
    buildAzureContentSafetyFilter: mockBuildFilter,
  }));

  // ── Mock anonymization helper ──────────────────────────────────────
  jest.doMock("../../../lib/anonymization-helper.js", () => ({
    VALID_ANONYMIZATION_ALGORITHM_PREFIXES: ["K-Anonymity", "Differential-Privacy", "L-Diversity"],
  }));

  // ── Load plugin ────────────────────────────────────────────────────
  const PluginClass = require("../../../srv/cap-llm-plugin.js");
  const plugin = new PluginClass();

  return {
    plugin,
    mocks: {
      cds: mockCds,
      dbRun: mockDbRun,
      embed: mockEmbed,
      chatCompletion: mockChatCompletion,
      buildFilter: mockBuildFilter,
      log: { debug: mockLogDebug, info: mockLogInfo, warn: mockLogWarn, error: mockLogError },
    },
  };
}

module.exports = { setupPlugin };
