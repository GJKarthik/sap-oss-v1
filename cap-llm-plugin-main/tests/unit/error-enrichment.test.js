/**
 * Unit tests for error context enrichment (Day 49).
 *
 * Verifies that upstream errors (EMBEDDING_REQUEST_FAILED,
 * CHAT_COMPLETION_REQUEST_FAILED) include the expected enriched
 * details: modelName, resourceGroup, deploymentUrl (when present), cause.
 */

"use strict";

const { EmbeddingError } = require("../../src/errors/EmbeddingError");
const { ChatCompletionError } = require("../../src/errors/ChatCompletionError");
const { AnonymizationError } = require("../../src/errors/AnonymizationError");
const { toErrorResponse, ERROR_HTTP_STATUS } = require("../../src/errors/LLMErrorResponse");

// ════════════════════════════════════════════════════════════════════
// Error code → HTTP status mapping (catalog contract)
// ════════════════════════════════════════════════════════════════════

describe("ERROR_HTTP_STATUS catalog contract", () => {
  const config400 = [
    "EMBEDDING_CONFIG_INVALID",
    "CHAT_CONFIG_INVALID",
    "INVALID_SEQUENCE_ID",
    "INVALID_ALGO_NAME",
    "UNSUPPORTED_FILTER_TYPE",
  ];

  const config404 = [
    "ENTITY_NOT_FOUND",
    "SEQUENCE_COLUMN_NOT_FOUND",
  ];

  const config500 = [
    "EMBEDDING_REQUEST_FAILED",
    "CHAT_COMPLETION_REQUEST_FAILED",
    "HARMONIZED_CHAT_FAILED",
    "CONTENT_FILTER_FAILED",
    "SIMILARITY_SEARCH_FAILED",
    "ANONYMIZATION_FAILED",
    "RAG_PIPELINE_FAILED",
    "UNKNOWN",
  ];

  test.each(config400)("%s maps to 400", (code) => {
    expect(ERROR_HTTP_STATUS[code]).toBe(400);
  });

  test.each(config404)("%s maps to 404", (code) => {
    expect(ERROR_HTTP_STATUS[code]).toBe(404);
  });

  test.each(config500)("%s maps to 500", (code) => {
    expect(ERROR_HTTP_STATUS[code]).toBe(500);
  });

  test("no registered code maps below 400", () => {
    for (const status of Object.values(ERROR_HTTP_STATUS)) {
      expect(status).toBeGreaterThanOrEqual(400);
    }
  });
});

// ════════════════════════════════════════════════════════════════════
// EMBEDDING_REQUEST_FAILED — enriched context
// ════════════════════════════════════════════════════════════════════

describe("EMBEDDING_REQUEST_FAILED — enriched error context", () => {
  test("includes modelName in details", () => {
    const err = new EmbeddingError("Embedding failed: timeout", "EMBEDDING_REQUEST_FAILED", {
      modelName: "text-embedding-ada-002",
      resourceGroup: "default",
      cause: "timeout",
    });
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(500);
    expect(body.error.details.modelName).toBe("text-embedding-ada-002");
  });

  test("includes resourceGroup in details", () => {
    const err = new EmbeddingError("Embedding failed", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002",
      resourceGroup: "prod-rg",
      cause: "503",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.resourceGroup).toBe("prod-rg");
  });

  test("includes deploymentUrl when provided", () => {
    const err = new EmbeddingError("Embedding failed", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002",
      resourceGroup: "default",
      deploymentUrl: "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2/inference/deployments/abc123",
      cause: "503",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.deploymentUrl).toBe(
      "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2/inference/deployments/abc123"
    );
  });

  test("omits deploymentUrl when not set", () => {
    const err = new EmbeddingError("Embedding failed", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002",
      resourceGroup: "default",
      cause: "timeout",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details).not.toHaveProperty("deploymentUrl");
  });

  test("includes cause in details", () => {
    const err = new EmbeddingError("Embedding failed: AI Core 503", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002",
      resourceGroup: "default",
      cause: "AI Core 503",
    });
    const { body } = toErrorResponse(err);
    expect(body.error.details.cause).toBe("AI Core 503");
  });

  test("message contains the upstream error description", () => {
    const err = new EmbeddingError(
      "Embedding request failed: connection refused",
      "EMBEDDING_REQUEST_FAILED",
      { modelName: "ada-002", resourceGroup: "default", cause: "connection refused" }
    );
    const { body } = toErrorResponse(err);
    expect(body.error.message).toContain("connection refused");
  });
});

// ════════════════════════════════════════════════════════════════════
// CHAT_COMPLETION_REQUEST_FAILED — enriched context
// ════════════════════════════════════════════════════════════════════

describe("CHAT_COMPLETION_REQUEST_FAILED — enriched error context", () => {
  test("includes modelName, resourceGroup, cause", () => {
    const err = new ChatCompletionError(
      "Chat completion request failed: rate limit exceeded",
      "CHAT_COMPLETION_REQUEST_FAILED",
      { modelName: "gpt-4o", resourceGroup: "default", cause: "rate limit exceeded" }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(500);
    expect(body.error.details.modelName).toBe("gpt-4o");
    expect(body.error.details.resourceGroup).toBe("default");
    expect(body.error.details.cause).toBe("rate limit exceeded");
  });

  test("includes deploymentUrl when provided", () => {
    const err = new ChatCompletionError(
      "Chat failed",
      "CHAT_COMPLETION_REQUEST_FAILED",
      {
        modelName: "gpt-4o",
        resourceGroup: "default",
        deploymentUrl: "https://example.com/v2/deployments/xyz",
        cause: "timeout",
      }
    );
    const { body } = toErrorResponse(err);
    expect(body.error.details.deploymentUrl).toBe("https://example.com/v2/deployments/xyz");
  });

  test("omits deploymentUrl when absent", () => {
    const err = new ChatCompletionError(
      "Chat failed",
      "CHAT_COMPLETION_REQUEST_FAILED",
      { modelName: "gpt-4o", resourceGroup: "default", cause: "err" }
    );
    const { body } = toErrorResponse(err);
    expect(body.error.details).not.toHaveProperty("deploymentUrl");
  });
});

// ════════════════════════════════════════════════════════════════════
// HARMONIZED_CHAT_FAILED — enriched context
// ════════════════════════════════════════════════════════════════════

describe("HARMONIZED_CHAT_FAILED — enriched error context", () => {
  test("includes cause in details", () => {
    const err = new ChatCompletionError(
      "Harmonized chat completion failed: invalid config",
      "HARMONIZED_CHAT_FAILED",
      { cause: "invalid config" }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(500);
    expect(body.error.details.cause).toBe("invalid config");
  });
});

// ════════════════════════════════════════════════════════════════════
// UNSUPPORTED_FILTER_TYPE — enriched context
// ════════════════════════════════════════════════════════════════════

describe("UNSUPPORTED_FILTER_TYPE — enriched context", () => {
  test("includes type and supportedTypes", () => {
    const err = new ChatCompletionError(
      "Unsupported type openai. The currently supported type is 'azure'.",
      "UNSUPPORTED_FILTER_TYPE",
      { type: "openai", supportedTypes: ["azure"] }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(400);
    expect(body.error.details.type).toBe("openai");
    expect(body.error.details.supportedTypes).toEqual(["azure"]);
  });
});

// ════════════════════════════════════════════════════════════════════
// ENTITY_NOT_FOUND — 404 with entityName
// ════════════════════════════════════════════════════════════════════

describe("ENTITY_NOT_FOUND — 404 with entityName", () => {
  test("returns 404 and includes entityName in details", () => {
    const err = new AnonymizationError(
      'Entity "MyService.MyEntity" not found.',
      "ENTITY_NOT_FOUND",
      { entityName: "MyService.MyEntity" }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(404);
    expect(body.error.code).toBe("ENTITY_NOT_FOUND");
    expect(body.error.details.entityName).toBe("MyService.MyEntity");
  });
});

// ════════════════════════════════════════════════════════════════════
// SEQUENCE_COLUMN_NOT_FOUND — 404
// ════════════════════════════════════════════════════════════════════

describe("SEQUENCE_COLUMN_NOT_FOUND — 404", () => {
  test("returns 404 and includes entityName", () => {
    const err = new AnonymizationError(
      "Sequence column not found.",
      "SEQUENCE_COLUMN_NOT_FOUND",
      { entityName: "MyService.Employees" }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(404);
    expect(body.error.details.entityName).toBe("MyService.Employees");
  });
});

// ════════════════════════════════════════════════════════════════════
// INVALID_SEQUENCE_ID — enriched with index + receivedType
// ════════════════════════════════════════════════════════════════════

describe("INVALID_SEQUENCE_ID — enriched context", () => {
  test("includes index and receivedType in details", () => {
    const err = new AnonymizationError(
      "Invalid sequenceId at index 2: must be string or number. Received: object",
      "INVALID_SEQUENCE_ID",
      { index: 2, receivedType: "object" }
    );
    const { httpStatus, body } = toErrorResponse(err);
    expect(httpStatus).toBe(400);
    expect(body.error.details.index).toBe(2);
    expect(body.error.details.receivedType).toBe("object");
  });
});

// ════════════════════════════════════════════════════════════════════
// Config validation — no stack traces, no sensitive data
// ════════════════════════════════════════════════════════════════════

describe("Error response safety", () => {
  test("error response body never contains a stack trace", () => {
    const errors = [
      new EmbeddingError("Embedding failed", "EMBEDDING_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", cause: "err" }),
      new ChatCompletionError("Chat failed", "CHAT_COMPLETION_REQUEST_FAILED", { modelName: "m", resourceGroup: "r", cause: "err" }),
      new AnonymizationError("Entity not found", "ENTITY_NOT_FOUND", { entityName: "X" }),
    ];

    for (const err of errors) {
      const { body } = toErrorResponse(err);
      const json = JSON.stringify(body);
      expect(json).not.toContain("at new ");
      expect(json).not.toContain(".ts:");
      expect(json).not.toContain(".js:");
    }
  });

  test("details fields are all serializable (no circular refs)", () => {
    const err = new EmbeddingError("Embedding failed", "EMBEDDING_REQUEST_FAILED", {
      modelName: "ada-002",
      resourceGroup: "default",
      deploymentUrl: "https://example.com",
      cause: "503",
    });
    const { body } = toErrorResponse(err);
    expect(() => JSON.stringify(body)).not.toThrow();
  });
});
