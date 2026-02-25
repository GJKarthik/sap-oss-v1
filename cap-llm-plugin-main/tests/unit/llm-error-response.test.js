/**
 * Unit tests for LLMErrorResponse — the canonical HTTP error response shape.
 *
 * Tests:
 *   - toErrorResponse() mapper for CAPLLMPluginError subclasses
 *   - toErrorResponse() mapper for generic Error
 *   - toErrorResponse() mapper for unknown throws
 *   - ERROR_HTTP_STATUS code → HTTP status mapping
 */

const { toErrorResponse, ERROR_HTTP_STATUS } = require("../../src/errors/LLMErrorResponse");

// We require the compiled JS. Since tsc hasn't run yet in tests, import the TS source via babel.
// Jest is configured with babel-plugin-transform-modules-commonjs, so require works on .js outputs.
// The errors are CommonJS-compatible after tsc.

let EmbeddingError, ChatCompletionError, AnonymizationError, SimilaritySearchError, CAPLLMPluginError;

beforeAll(() => {
  // Load compiled outputs (tsc must have run — enforced by CI build step)
  ({ EmbeddingError } = require("../../src/errors/EmbeddingError"));
  ({ ChatCompletionError } = require("../../src/errors/ChatCompletionError"));
  ({ AnonymizationError } = require("../../src/errors/AnonymizationError"));
  ({ SimilaritySearchError } = require("../../src/errors/SimilaritySearchError"));
  ({ CAPLLMPluginError } = require("../../src/errors/CAPLLMPluginError"));
});

describe("toErrorResponse — CAPLLMPluginError subclasses", () => {
  test("EmbeddingError with EMBEDDING_CONFIG_INVALID → 400", () => {
    const err = new EmbeddingError('The config is missing the parameter: "modelName".', "EMBEDDING_CONFIG_INVALID", {
      missingField: "modelName",
    });
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(400);
    expect(body.error.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(body.error.message).toContain("modelName");
    expect(body.error.details).toEqual({ missingField: "modelName" });
  });

  test("EmbeddingError with EMBEDDING_REQUEST_FAILED → 500", () => {
    const err = new EmbeddingError("Embedding request failed: upstream timeout", "EMBEDDING_REQUEST_FAILED", {
      modelName: "text-embedding-ada-002",
      cause: "upstream timeout",
    });
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("EMBEDDING_REQUEST_FAILED");
    expect(body.error.details.modelName).toBe("text-embedding-ada-002");
  });

  test("ChatCompletionError with CHAT_CONFIG_INVALID → 400", () => {
    const err = new ChatCompletionError('The config is missing parameter: "resourceGroup".', "CHAT_CONFIG_INVALID", {
      missingField: "resourceGroup",
    });
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(400);
    expect(body.error.code).toBe("CHAT_CONFIG_INVALID");
  });

  test("ChatCompletionError with UNSUPPORTED_FILTER_TYPE → 400", () => {
    const err = new ChatCompletionError("Unsupported type openai.", "UNSUPPORTED_FILTER_TYPE", {
      type: "openai",
      supportedTypes: ["azure"],
    });
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(400);
    expect(body.error.details.supportedTypes).toEqual(["azure"]);
  });

  test("AnonymizationError with ENTITY_NOT_FOUND → 404", () => {
    const err = new AnonymizationError('Entity "MyService.MyEntity" not found.', "ENTITY_NOT_FOUND", {
      entityName: "MyService.MyEntity",
    });
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(404);
    expect(body.error.code).toBe("ENTITY_NOT_FOUND");
  });

  test("AnonymizationError with SEQUENCE_COLUMN_NOT_FOUND → 404", () => {
    const err = new AnonymizationError("Sequence column not found.", "SEQUENCE_COLUMN_NOT_FOUND", {
      entityName: "MyEntity",
    });
    const { httpStatus } = toErrorResponse(err);

    expect(httpStatus).toBe(404);
  });

  test("SimilaritySearchError with SIMILARITY_SEARCH_FAILED → 500", () => {
    const err = new SimilaritySearchError("DB query failed.", "SIMILARITY_SEARCH_FAILED", {
      cause: "connection timeout",
    });
    const { httpStatus } = toErrorResponse(err);

    expect(httpStatus).toBe(500);
  });

  test("base CAPLLMPluginError with unknown code → 500 fallback", () => {
    const err = new CAPLLMPluginError("Something unexpected.", "SOME_NEW_CODE");
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("SOME_NEW_CODE");
  });

  test("error with empty details is omitted from response", () => {
    const err = new EmbeddingError("Config missing.", "EMBEDDING_CONFIG_INVALID", {});
    const { body } = toErrorResponse(err);

    expect(body.error.details).toBeUndefined();
  });

  test("error without details is omitted from response", () => {
    const err = new EmbeddingError("Config missing.", "EMBEDDING_CONFIG_INVALID");
    const { body } = toErrorResponse(err);

    expect(body.error.details).toBeUndefined();
  });
});

describe("toErrorResponse — generic Error", () => {
  test("plain Error → 500 with UNKNOWN code", () => {
    const err = new Error("something went wrong");
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("UNKNOWN");
    expect(body.error.message).toBe("something went wrong");
    expect(body.error.innerError).toBeDefined();
    expect(body.error.innerError.message).toBe("something went wrong");
  });

  test("TypeError → 500 with UNKNOWN code", () => {
    const err = new TypeError("Cannot read property 'x' of undefined");
    const { httpStatus, body } = toErrorResponse(err);

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("UNKNOWN");
  });
});

describe("toErrorResponse — non-Error throws", () => {
  test("thrown string → 500 generic message", () => {
    const { httpStatus, body } = toErrorResponse("something broke");

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("UNKNOWN");
    expect(body.error.message).toBe("An unexpected error occurred.");
  });

  test("thrown null → 500 generic message", () => {
    const { httpStatus, body } = toErrorResponse(null);

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("UNKNOWN");
  });

  test("thrown object → 500 generic message", () => {
    const { httpStatus, body } = toErrorResponse({ foo: "bar" });

    expect(httpStatus).toBe(500);
    expect(body.error.code).toBe("UNKNOWN");
  });
});

describe("ERROR_HTTP_STATUS — all known codes have mappings", () => {
  const expectedCodes = [
    "EMBEDDING_CONFIG_INVALID",
    "CHAT_CONFIG_INVALID",
    "INVALID_SEQUENCE_ID",
    "INVALID_ALGO_NAME",
    "UNSUPPORTED_FILTER_TYPE",
    "ENTITY_NOT_FOUND",
    "SEQUENCE_COLUMN_NOT_FOUND",
    "EMBEDDING_REQUEST_FAILED",
    "CHAT_COMPLETION_REQUEST_FAILED",
    "HARMONIZED_CHAT_FAILED",
    "CONTENT_FILTER_FAILED",
    "SIMILARITY_SEARCH_FAILED",
    "ANONYMIZATION_FAILED",
    "RAG_PIPELINE_FAILED",
    "UNKNOWN",
  ];

  test.each(expectedCodes)("ERROR_HTTP_STATUS[%s] is defined", (code) => {
    expect(ERROR_HTTP_STATUS[code]).toBeDefined();
    expect(typeof ERROR_HTTP_STATUS[code]).toBe("number");
  });

  test("config validation codes map to 400", () => {
    expect(ERROR_HTTP_STATUS.EMBEDDING_CONFIG_INVALID).toBe(400);
    expect(ERROR_HTTP_STATUS.CHAT_CONFIG_INVALID).toBe(400);
    expect(ERROR_HTTP_STATUS.INVALID_SEQUENCE_ID).toBe(400);
    expect(ERROR_HTTP_STATUS.INVALID_ALGO_NAME).toBe(400);
    expect(ERROR_HTTP_STATUS.UNSUPPORTED_FILTER_TYPE).toBe(400);
  });

  test("not-found codes map to 404", () => {
    expect(ERROR_HTTP_STATUS.ENTITY_NOT_FOUND).toBe(404);
    expect(ERROR_HTTP_STATUS.SEQUENCE_COLUMN_NOT_FOUND).toBe(404);
  });

  test("upstream failure codes map to 500", () => {
    expect(ERROR_HTTP_STATUS.EMBEDDING_REQUEST_FAILED).toBe(500);
    expect(ERROR_HTTP_STATUS.CHAT_COMPLETION_REQUEST_FAILED).toBe(500);
    expect(ERROR_HTTP_STATUS.HARMONIZED_CHAT_FAILED).toBe(500);
    expect(ERROR_HTTP_STATUS.CONTENT_FILTER_FAILED).toBe(500);
    expect(ERROR_HTTP_STATUS.SIMILARITY_SEARCH_FAILED).toBe(500);
    expect(ERROR_HTTP_STATUS.UNKNOWN).toBe(500);
  });
});

describe("LLMErrorResponse body shape", () => {
  test("body always has top-level error key", () => {
    const { body } = toErrorResponse(new Error("test"));
    expect(body).toHaveProperty("error");
  });

  test("error always has code and message", () => {
    const err = new EmbeddingError("missing field", "EMBEDDING_CONFIG_INVALID");
    const { body } = toErrorResponse(err);
    expect(body.error).toHaveProperty("code");
    expect(body.error).toHaveProperty("message");
  });

  test("target field is not set by toErrorResponse (set by caller if needed)", () => {
    const err = new EmbeddingError("missing modelName", "EMBEDDING_CONFIG_INVALID", { missingField: "modelName" });
    const { body } = toErrorResponse(err);
    // toErrorResponse doesn't auto-populate target; callers can extend the body
    expect(body.error.target).toBeUndefined();
  });
});
