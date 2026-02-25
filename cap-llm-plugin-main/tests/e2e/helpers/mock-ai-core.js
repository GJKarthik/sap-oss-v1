/**
 * E2E Test Helpers — Mock AI Core SDK Responses
 *
 * Provides realistic mock responses that simulate the SAP AI Core
 * Orchestration SDK behavior for end-to-end pipeline testing.
 */

/** Simulates an embedding response from OrchestrationEmbeddingClient. */
function createEmbeddingResponse(vector = null) {
  const defaultVector = Array.from({ length: 1536 }, (_, i) =>
    Math.sin(i * 0.01),
  );
  return {
    getEmbeddings: () => [{ embedding: vector || defaultVector }],
  };
}

/** Simulates a chat completion response from OrchestrationClient. */
function createChatCompletionResponse(content = "This is a mock AI response.") {
  return {
    getContent: () => content,
    getTokenUsage: () => ({
      completion_tokens: 42,
      prompt_tokens: 100,
      total_tokens: 142,
    }),
    getFinishReason: () => "stop",
    data: {
      orchestration_result: {
        choices: [
          {
            message: { role: "assistant", content },
            finish_reason: "stop",
          },
        ],
        usage: {
          completion_tokens: 42,
          prompt_tokens: 100,
          total_tokens: 142,
        },
      },
    },
  };
}

/** Simulates a content filter configuration from buildAzureContentSafetyFilter. */
function createContentFilter() {
  return {
    type: "azure_content_safety",
    config: {
      Hate: 2,
      Violence: 2,
      SelfHarm: 2,
      Sexual: 2,
    },
  };
}

/** Simulates similarity search results from HANA. */
function createSimilaritySearchRows(count = 3) {
  return Array.from({ length: count }, (_, i) => ({
    PAGE_CONTENT: `Document chunk ${i + 1}: This is relevant content about the topic.`,
    SCORE: parseFloat((0.95 - i * 0.05).toFixed(2)),
  }));
}

module.exports = {
  createEmbeddingResponse,
  createChatCompletionResponse,
  createContentFilter,
  createSimilaritySearchRows,
};
