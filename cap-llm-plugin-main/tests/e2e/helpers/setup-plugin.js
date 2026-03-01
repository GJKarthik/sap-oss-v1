// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * E2E Test Helper — Plugin Setup
 *
 * Creates a fully wired CAPLLMPlugin instance with stubbed CDS and SDK
 * dependencies for end-to-end pipeline testing.
 */

// ── Inline response fixtures ───────────────────────────────────────────────

function createEmbeddingResponse(vector = null) {
  const defaultVector = Array.from({ length: 1536 }, (_, i) => Math.sin(i * 0.01));
  return { getEmbeddings: () => [{ embedding: vector || defaultVector }] };
}

function createChatCompletionResponse(content = "This is a test AI response.") {
  return {
    getContent: () => content,
    getTokenUsage: () => ({ completion_tokens: 42, prompt_tokens: 100, total_tokens: 142 }),
    getFinishReason: () => "stop",
    data: {
      orchestration_result: {
        choices: [{ message: { role: "assistant", content }, finish_reason: "stop" }],
        usage: { completion_tokens: 42, prompt_tokens: 100, total_tokens: 142 },
      },
    },
  };
}

function createContentFilter() {
  return { type: "azure_content_safety", config: { Hate: 2, Violence: 2, SelfHarm: 2, Sexual: 2 } };
}

function createSimilaritySearchRows(count = 3) {
  return Array.from({ length: count }, (_, i) => ({
    PAGE_CONTENT: `Document chunk ${i + 1}: This is relevant content about the topic.`,
    SCORE: parseFloat((0.95 - i * 0.05).toFixed(2)),
  }));
}

/**
 * Set up mocks and load the plugin for E2E testing.
 *
 * @param {object} overrides - Optional overrides for mock behavior.
 * @param {Function} overrides.dbRun - Custom mock for cds.db.run
 * @param {Function} overrides.embed - Custom mock for OrchestrationEmbeddingClient.embed
 * @param {Function} overrides.chatCompletion - Custom mock for OrchestrationClient.chatCompletion
 * @param {Function} overrides.stream - Custom mock for OrchestrationClient.stream
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
  const mockStream = overrides.stream || jest.fn().mockResolvedValue({
    stream: { [Symbol.asyncIterator]: async function* () {} },
    getFinishReason: () => "stop",
    getTokenUsage: () => ({ total_tokens: 0 }),
  });
  const mockBuildFilter = overrides.buildFilter || jest.fn().mockReturnValue(createContentFilter());

  jest.doMock("@sap-ai-sdk/orchestration", () => ({
    OrchestrationEmbeddingClient: jest.fn().mockImplementation(() => ({
      embed: mockEmbed,
    })),
    OrchestrationClient: jest.fn().mockImplementation(() => ({
      chatCompletion: mockChatCompletion,
      stream: mockStream,
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
      stream: mockStream,
      buildFilter: mockBuildFilter,
      log: { debug: mockLogDebug, info: mockLogInfo, warn: mockLogWarn, error: mockLogError },
    },
  };
}

module.exports = { setupPlugin };
