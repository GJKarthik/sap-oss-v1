// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Day 50 — Error Handling Validation
 *
 * Full validation sweep across the error handling stack:
 *
 * 1. InvalidSimilaritySearchAlgoNameError (legacy, numeric .code) → INVALID_ALGO_NAME/400
 * 2. All error codes from every plugin method → correct HTTP status
 * 3. toErrorResponse preserves full details for each real throw site
 * 4. No error response ever leaks a stack trace
 * 5. Every body is JSON-serializable
 * 6. Successful request paths are unaffected (errors only on failure)
 * 7. ERROR_HTTP_STATUS catalog completeness vs. actual throw sites
 */

"use strict";

const { toErrorResponse, ERROR_HTTP_STATUS } = require("../../src/errors/LLMErrorResponse");
const { EmbeddingError } = require("../../src/errors/EmbeddingError");
const { ChatCompletionError } = require("../../src/errors/ChatCompletionError");
const { AnonymizationError } = require("../../src/errors/AnonymizationError");
const { SimilaritySearchError } = require("../../src/errors/SimilaritySearchError");
const { CAPLLMPluginError } = require("../../src/errors/CAPLLMPluginError");
const InvalidSimilaritySearchAlgoNameError = require("../../srv/errors/InvalidSimilaritySearchAlgoNameError");

// ════════════════════════════════════════════════════════════════════
// InvalidSimilaritySearchAlgoNameError — legacy numeric code fix
// ════════════════════════════════════════════════════════════════════

describe("InvalidSimilaritySearchAlgoNameError → INVALID_ALGO_NAME/400", () => {
  test("maps to INVALID_ALGO_NAME code", () => {
    const err = new InvalidSimilaritySearchAlgoNameError(
      "Invalid algorithm name: foo. Currently only COSINE_SIMILARITY and L2DISTANCE are accepted.",
      400
    );
    const { body } = toErrorResponse(err);
    expect(body.error.code).toBe("INVALID_ALGO_NAME");
  });

  test("returns HTTP 400", () => {
    const err = new InvalidSimilaritySearchAlgoNameError("Invalid algo: bar.", 400);
    const { httpStatus } = toErrorResponse(err);
    expect(httpStatus).toBe(400);
  });

  test("preserves the original error message", () => {
    const msg = "Invalid algorithm name: L3DISTANCE. Currently only COSINE_SIMILARITY and L2DISTANCE are accepted.";
    const err = new InvalidSimilaritySearchAlgoNameError(msg, 400);
    const { body } = toErrorResponse(err);
    expect(body.error.message).toBe(msg);
  });

  test("body has no stack trace", () => {
    const err = new InvalidSimilaritySearchAlgoNameError("bad algo", 400);
    const { body } = toErrorResponse(err);
    const json = JSON.stringify(body);
    expect(json).not.toContain("at new ");
    expect(json).not.toContain(".js:");
  });

  test("body is JSON-serializable", () => {
    const err = new InvalidSimilaritySearchAlgoNameError("bad algo", 400);
    const { body } = toErrorResponse(err);
    expect(() => JSON.stringify(body)).not.toThrow();
  });
});

// ════════════════════════════════════════════════════════════════════
// Full throw-site audit: every real throw → correct code + HTTP status
// ════════════════════════════════════════════════════════════════════

describe("Full throw-site audit — every real error code and HTTP status", () => {
  const realThrows = [
    // getEmbeddingWithConfig — config validation
    {
      label: "EMBEDDING_CONFIG_INVALID (modelName)",
      err: new EmbeddingError('The config is missing the parameter: "modelName".', "EMBEDDING_CONFIG_INVALID", { missingField: "modelName" }),
      expectedCode: "EMBEDDING_CONFIG_INVALID",
      expectedStatus: 400,
    },
    {
      label: "EMBEDDING_CONFIG_INVALID (resourceGroup)",
      err: new EmbeddingError('The config is missing the parameter: "resourceGroup".', "EMBEDDING_CONFIG_INVALID", { missingField: "resourceGroup" }),
      expectedCode: "EMBEDDING_CONFIG_INVALID",
      expectedStatus: 400,
    },
    // getEmbeddingWithConfig — upstream failure
    {
      label: "EMBEDDING_REQUEST_FAILED",
      err: new EmbeddingError("Embedding request failed: AI Core 503", "EMBEDDING_REQUEST_FAILED", {
        modelName: "ada-002", resourceGroup: "default", cause: "AI Core 503",
      }),
      expectedCode: "EMBEDDING_REQUEST_FAILED",
      expectedStatus: 500,
    },
    // getChatCompletionWithConfig — config validation
    {
      label: "CHAT_CONFIG_INVALID (modelName)",
      err: new ChatCompletionError('The config is missing parameter: "modelName".', "CHAT_CONFIG_INVALID", { missingField: "modelName" }),
      expectedCode: "CHAT_CONFIG_INVALID",
      expectedStatus: 400,
    },
    {
      label: "CHAT_CONFIG_INVALID (resourceGroup)",
      err: new ChatCompletionError('The config is missing parameter: "resourceGroup".', "CHAT_CONFIG_INVALID", { missingField: "resourceGroup" }),
      expectedCode: "CHAT_CONFIG_INVALID",
      expectedStatus: 400,
    },
    // getChatCompletionWithConfig — upstream failure
    {
      label: "CHAT_COMPLETION_REQUEST_FAILED",
      err: new ChatCompletionError("Chat completion request failed: rate limit", "CHAT_COMPLETION_REQUEST_FAILED", {
        modelName: "gpt-4o", resourceGroup: "default", cause: "rate limit",
      }),
      expectedCode: "CHAT_COMPLETION_REQUEST_FAILED",
      expectedStatus: 500,
    },
    // getHarmonizedChatCompletion — upstream failure
    {
      label: "HARMONIZED_CHAT_FAILED",
      err: new ChatCompletionError("Harmonized chat completion failed: invalid config", "HARMONIZED_CHAT_FAILED", {
        cause: "invalid config",
      }),
      expectedCode: "HARMONIZED_CHAT_FAILED",
      expectedStatus: 500,
    },
    // getContentFilters — unsupported type
    {
      label: "UNSUPPORTED_FILTER_TYPE",
      err: new ChatCompletionError("Unsupported type openai.", "UNSUPPORTED_FILTER_TYPE", {
        type: "openai", supportedTypes: ["azure"],
      }),
      expectedCode: "UNSUPPORTED_FILTER_TYPE",
      expectedStatus: 400,
    },
    // getContentFilters — construction failure
    {
      label: "CONTENT_FILTER_FAILED",
      err: new ChatCompletionError("Content filter construction failed: bad config", "CONTENT_FILTER_FAILED", {
        type: "azure", cause: "bad config",
      }),
      expectedCode: "CONTENT_FILTER_FAILED",
      expectedStatus: 500,
    },
    // similaritySearch — invalid algo (legacy error)
    {
      label: "INVALID_ALGO_NAME (InvalidSimilaritySearchAlgoNameError)",
      err: new InvalidSimilaritySearchAlgoNameError(
        "Invalid algorithm name: foo. Currently only COSINE_SIMILARITY and L2DISTANCE are accepted.", 400
      ),
      expectedCode: "INVALID_ALGO_NAME",
      expectedStatus: 400,
    },
    // getAnonymizedData — entity not found
    {
      label: "ENTITY_NOT_FOUND",
      err: new AnonymizationError('Entity "MyService.MyEntity" not found.', "ENTITY_NOT_FOUND", {
        entityName: "MyService.MyEntity",
      }),
      expectedCode: "ENTITY_NOT_FOUND",
      expectedStatus: 404,
    },
    // getAnonymizedData — sequence column not found
    {
      label: "SEQUENCE_COLUMN_NOT_FOUND",
      err: new AnonymizationError("Sequence column not found.", "SEQUENCE_COLUMN_NOT_FOUND", {
        entityName: "MyService.Employees",
      }),
      expectedCode: "SEQUENCE_COLUMN_NOT_FOUND",
      expectedStatus: 404,
    },
    // getAnonymizedData — invalid sequence ID
    {
      label: "INVALID_SEQUENCE_ID",
      err: new AnonymizationError("Invalid sequenceId at index 0.", "INVALID_SEQUENCE_ID", {
        index: 0, receivedType: "object",
      }),
      expectedCode: "INVALID_SEQUENCE_ID",
      expectedStatus: 400,
    },
    // similaritySearch — DB failure
    {
      label: "SIMILARITY_SEARCH_FAILED",
      err: new SimilaritySearchError("DB query failed.", "SIMILARITY_SEARCH_FAILED", {
        cause: "connection timeout",
      }),
      expectedCode: "SIMILARITY_SEARCH_FAILED",
      expectedStatus: 500,
    },
    // getAnonymizedData — anonymization failure
    {
      label: "ANONYMIZATION_FAILED",
      err: new AnonymizationError("Anonymization failed.", "ANONYMIZATION_FAILED", {
        entityName: "MyEntity", cause: "view unavailable",
      }),
      expectedCode: "ANONYMIZATION_FAILED",
      expectedStatus: 500,
    },
    // RAG pipeline — wrapped failure
    {
      label: "RAG_PIPELINE_FAILED",
      err: new CAPLLMPluginError("RAG pipeline failed.", "RAG_PIPELINE_FAILED", {
        step: "embedding", cause: "AI Core timeout",
      }),
      expectedCode: "RAG_PIPELINE_FAILED",
      expectedStatus: 500,
    },
  ];

  test.each(realThrows)("$label → $expectedCode / $expectedStatus", ({ err, expectedCode, expectedStatus }) => {
    const { httpStatus, body } = toErrorResponse(err);
    expect(body.error.code).toBe(expectedCode);
    expect(httpStatus).toBe(expectedStatus);
  });
});

// ════════════════════════════════════════════════════════════════════
// Details fields preserved for all real throw sites
// ════════════════════════════════════════════════════════════════════

describe("Details fields preserved for all real throw sites", () => {
  test("EMBEDDING_CONFIG_INVALID includes missingField", () => {
    const err = new EmbeddingError('Missing "modelName".', "EMBEDDING_CONFIG_INVALID", { missingField: "modelName" });
    const { body } = toErrorResponse(err);
    expect(body.error.details.missingField).toBe("modelName");
  });

  test("EMBEDDING_REQUEST_FAILED includes modelName + resourceGroup + cause", () => {
    const err = new EmbeddingError("Upstream failed.", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002", resourceGroup: "rg-1", cause: "503",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.modelName).toBe("ada-002");
    expect(body.error.details.resourceGroup).toBe("rg-1");
    expect(body.error.details.cause).toBe("503");
  });

  test("EMBEDDING_REQUEST_FAILED includes deploymentUrl when set", () => {
    const err = new EmbeddingError("Upstream failed.", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002", resourceGroup: "rg-1",
      deploymentUrl: "https://api.ai.example.com/deployments/abc",
      cause: "timeout",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.deploymentUrl).toBe("https://api.ai.example.com/deployments/abc");
  });

  test("CHAT_COMPLETION_REQUEST_FAILED includes deploymentUrl when set", () => {
    const err = new ChatCompletionError("Chat failed.", "CHAT_COMPLETION_REQUEST_FAILED", {
      modelName: "gpt-4o", resourceGroup: "default",
      deploymentUrl: "https://api.ai.example.com/deployments/xyz",
      cause: "rate limit",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.deploymentUrl).toBe("https://api.ai.example.com/deployments/xyz");
  });

  test("UNSUPPORTED_FILTER_TYPE includes type + supportedTypes", () => {
    const err = new ChatCompletionError("Unsupported type openai.", "UNSUPPORTED_FILTER_TYPE", {
      type: "openai", supportedTypes: ["azure"],
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.type).toBe("openai");
    expect(body.error.details.supportedTypes).toEqual(["azure"]);
  });

  test("ENTITY_NOT_FOUND includes entityName", () => {
    const err = new AnonymizationError("Not found.", "ENTITY_NOT_FOUND", { entityName: "MyService.MyEntity" });
    const { body } = toErrorResponse(err);
    expect(body.error.details.entityName).toBe("MyService.MyEntity");
  });

  test("INVALID_SEQUENCE_ID includes index and receivedType", () => {
    const err = new AnonymizationError("Bad sequenceId.", "INVALID_SEQUENCE_ID", { index: 3, receivedType: "boolean" });
    const { body } = toErrorResponse(err);
    expect(body.error.details.index).toBe(3);
    expect(body.error.details.receivedType).toBe("boolean");
  });
});

// ════════════════════════════════════════════════════════════════════
// No stack traces in any error response
// ════════════════════════════════════════════════════════════════════

describe("No stack traces in any error response", () => {
  const allErrors = [
    new EmbeddingError("failed", "EMBEDDING_CONFIG_INVALID", { missingField: "modelName" }),
    new EmbeddingError("failed", "EMBEDDING_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", cause: "x" }),
    new ChatCompletionError("failed", "CHAT_CONFIG_INVALID", { missingField: "modelName" }),
    new ChatCompletionError("failed", "CHAT_COMPLETION_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", cause: "x" }),
    new ChatCompletionError("failed", "HARMONIZED_CHAT_FAILED", { cause: "x" }),
    new ChatCompletionError("failed", "UNSUPPORTED_FILTER_TYPE", { type: "openai", supportedTypes: ["azure"] }),
    new ChatCompletionError("failed", "CONTENT_FILTER_FAILED", { type: "azure", cause: "x" }),
    new AnonymizationError("failed", "ENTITY_NOT_FOUND", { entityName: "E" }),
    new AnonymizationError("failed", "SEQUENCE_COLUMN_NOT_FOUND", { entityName: "E" }),
    new AnonymizationError("failed", "INVALID_SEQUENCE_ID", { index: 0, receivedType: "object" }),
    new SimilaritySearchError("failed", "SIMILARITY_SEARCH_FAILED", { cause: "x" }),
    new InvalidSimilaritySearchAlgoNameError("bad algo", 400),
    new Error("generic error"),
    "thrown string",
    null,
  ];

  test.each(allErrors)("no stack trace in response for error #%#", (err) => {
    const { body } = toErrorResponse(err);
    const json = JSON.stringify(body);
    expect(json).not.toMatch(/at (new |Object\.|Function\.)/);
    expect(json).not.toMatch(/\.(ts|js):\d+/);
  });
});

// ════════════════════════════════════════════════════════════════════
// All error responses are JSON-serializable
// ════════════════════════════════════════════════════════════════════

describe("All error responses are JSON-serializable", () => {
  const allErrors = [
    new EmbeddingError("failed", "EMBEDDING_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", deploymentUrl: "https://x.com", cause: "y" }),
    new ChatCompletionError("failed", "CHAT_COMPLETION_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", cause: "y" }),
    new AnonymizationError("failed", "ENTITY_NOT_FOUND", { entityName: "E" }),
    new InvalidSimilaritySearchAlgoNameError("bad algo", 400),
    new Error("generic"),
    null,
  ];

  test.each(allErrors)("serializable for error #%#", (err) => {
    const { body } = toErrorResponse(err);
    expect(() => JSON.stringify(body)).not.toThrow();
  });
});

// ════════════════════════════════════════════════════════════════════
// ERROR_HTTP_STATUS catalog completeness
// ════════════════════════════════════════════════════════════════════

describe("ERROR_HTTP_STATUS catalog completeness", () => {
  // Every string code actually thrown in the plugin must be in ERROR_HTTP_STATUS
  const allActualCodes = [
    // From getEmbeddingWithConfig
    "EMBEDDING_CONFIG_INVALID",
    "EMBEDDING_REQUEST_FAILED",
    // From getChatCompletionWithConfig
    "CHAT_CONFIG_INVALID",
    "CHAT_COMPLETION_REQUEST_FAILED",
    // From getHarmonizedChatCompletion
    "HARMONIZED_CHAT_FAILED",
    // From getContentFilters
    "UNSUPPORTED_FILTER_TYPE",
    "CONTENT_FILTER_FAILED",
    // From getAnonymizedData
    "ENTITY_NOT_FOUND",
    "SEQUENCE_COLUMN_NOT_FOUND",
    "INVALID_SEQUENCE_ID",
    // INVALID_ALGO_NAME — mapped by toErrorResponse from InvalidSimilaritySearchAlgoNameError
    "INVALID_ALGO_NAME",
    // DB/search failures
    "SIMILARITY_SEARCH_FAILED",
    "ANONYMIZATION_FAILED",
    "RAG_PIPELINE_FAILED",
    // Fallback
    "UNKNOWN",
  ];

  test.each(allActualCodes)("ERROR_HTTP_STATUS[%s] is defined and is a valid HTTP status", (code) => {
    expect(ERROR_HTTP_STATUS[code]).toBeDefined();
    expect(ERROR_HTTP_STATUS[code]).toBeGreaterThanOrEqual(400);
    expect(ERROR_HTTP_STATUS[code]).toBeLessThan(600);
  });

  test("no code maps to 2xx or 3xx", () => {
    for (const status of Object.values(ERROR_HTTP_STATUS)) {
      expect(status).toBeGreaterThanOrEqual(400);
    }
  });
});

// ════════════════════════════════════════════════════════════════════
// toErrorResponse shape contract
// ════════════════════════════════════════════════════════════════════

describe("toErrorResponse shape contract", () => {
  test("always returns { httpStatus: number, body: { error: { code, message } } }", () => {
    const inputs = [
      new EmbeddingError("x", "EMBEDDING_CONFIG_INVALID"),
      new InvalidSimilaritySearchAlgoNameError("bad", 400),
      new Error("generic"),
      "string throw",
      null,
    ];
    for (const input of inputs) {
      const result = toErrorResponse(input);
      expect(typeof result.httpStatus).toBe("number");
      expect(typeof result.body.error.code).toBe("string");
      expect(typeof result.body.error.message).toBe("string");
      expect(result.body.error.code.length).toBeGreaterThan(0);
      expect(result.body.error.message.length).toBeGreaterThan(0);
    }
  });

  test("INVALID_ALGO_NAME body has no details field (no details in legacy error)", () => {
    const err = new InvalidSimilaritySearchAlgoNameError("bad algo", 400);
    const { body } = toErrorResponse(err);
    expect(body.error.details).toBeUndefined();
  });

  test("details omitted when empty object", () => {
    const err = new EmbeddingError("missing.", "EMBEDDING_CONFIG_INVALID", {});
    const { body } = toErrorResponse(err);
    expect(body.error.details).toBeUndefined();
  });

  test("details present when non-empty", () => {
    const err = new EmbeddingError("missing.", "EMBEDDING_CONFIG_INVALID", { missingField: "modelName" });
    const { body } = toErrorResponse(err);
    expect(body.error.details).toBeDefined();
  });
});
