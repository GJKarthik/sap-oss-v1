/**
 * Unit tests for LLMErrorInterceptor — extractErrorDetail logic (Day 48).
 *
 * Tests the pure error-parsing logic without requiring Angular or RxJS.
 * The extractErrorDetail function is re-implemented here as a pure function
 * (identical logic to examples/angular-demo/error.interceptor.ts) so these
 * tests verify the contract without an Angular test bed.
 */

"use strict";

// ── Minimal HttpErrorResponse stand-in ──────────────────────────────

class MockHttpErrorResponse {
  constructor({ error = null, status = 500, statusText = "Internal Server Error", message } = {}) {
    this.name = "HttpErrorResponse";
    this.error = error;
    this.status = status;
    this.statusText = statusText;
    this.message = message ?? `Http failure response: ${status}`;
  }
}

// ── Pure re-implementation matching error.interceptor.ts logic ──────
// Must stay structurally in sync with extractErrorDetail in
// examples/angular-demo/error.interceptor.ts

function extractErrorDetail(err) {
  if (err && err.name === "HttpErrorResponse") {
    const body = err.error;
    if (body?.error?.code && body?.error?.message) {
      return {
        code: body.error.code,
        message: body.error.message,
        ...(body.error.target !== undefined ? { target: body.error.target } : {}),
        ...(body.error.details !== undefined ? { details: body.error.details } : {}),
        ...(body.error.innerError !== undefined ? { innerError: body.error.innerError } : {}),
      };
    }
    return {
      code: `HTTP_${err.status}`,
      message: err.message || `HTTP ${err.status} ${err.statusText}`,
    };
  }
  if (err instanceof Error) {
    return { code: "NETWORK_ERROR", message: err.message };
  }
  return { code: "UNKNOWN", message: "An unexpected error occurred." };
}

// ════════════════════════════════════════════════════════════════════
// LLMErrorResponse body — config validation errors (400)
// ════════════════════════════════════════════════════════════════════

describe("extractErrorDetail — LLMErrorResponse 400 config errors", () => {
  test("EMBEDDING_CONFIG_INVALID missing modelName", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "EMBEDDING_CONFIG_INVALID", message: 'Missing "modelName".', details: { missingField: "modelName" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(detail.message).toContain("modelName");
    expect(detail.details).toEqual({ missingField: "modelName" });
  });

  test("EMBEDDING_CONFIG_INVALID missing resourceGroup", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "EMBEDDING_CONFIG_INVALID", message: 'Missing "resourceGroup".', details: { missingField: "resourceGroup" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("EMBEDDING_CONFIG_INVALID");
    expect(detail.details.missingField).toBe("resourceGroup");
  });

  test("CHAT_CONFIG_INVALID missing modelName", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "CHAT_CONFIG_INVALID", message: 'Missing "modelName".', details: { missingField: "modelName" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("CHAT_CONFIG_INVALID");
    expect(detail.details.missingField).toBe("modelName");
  });

  test("CHAT_CONFIG_INVALID missing resourceGroup", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "CHAT_CONFIG_INVALID", message: 'Missing "resourceGroup".', details: { missingField: "resourceGroup" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("CHAT_CONFIG_INVALID");
  });

  test("UNSUPPORTED_FILTER_TYPE with supportedTypes in details", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "UNSUPPORTED_FILTER_TYPE", message: "Unsupported type openai.", details: { type: "openai", supportedTypes: ["azure"] } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("UNSUPPORTED_FILTER_TYPE");
    expect(detail.details.supportedTypes).toContain("azure");
  });

  test("INVALID_ALGO_NAME", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "INVALID_ALGO_NAME", message: "Invalid algo: foo.", details: { algoName: "foo" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("INVALID_ALGO_NAME");
    expect(detail.details.algoName).toBe("foo");
  });
});

// ════════════════════════════════════════════════════════════════════
// LLMErrorResponse body — not-found (404) and upstream (500)
// ════════════════════════════════════════════════════════════════════

describe("extractErrorDetail — LLMErrorResponse 404 and 500 errors", () => {
  test("ENTITY_NOT_FOUND 404", () => {
    const err = new MockHttpErrorResponse({
      status: 404,
      error: { error: { code: "ENTITY_NOT_FOUND", message: 'Entity "MyService.MyEntity" not found.', details: { entityName: "MyService.MyEntity" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("ENTITY_NOT_FOUND");
    expect(detail.details.entityName).toBe("MyService.MyEntity");
  });

  test("EMBEDDING_REQUEST_FAILED 500 with cause in details", () => {
    const err = new MockHttpErrorResponse({
      status: 500,
      error: { error: { code: "EMBEDDING_REQUEST_FAILED", message: "Upstream timeout.", details: { cause: "timeout", modelName: "ada-002" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("EMBEDDING_REQUEST_FAILED");
    expect(detail.details.cause).toBe("timeout");
    expect(detail.details.modelName).toBe("ada-002");
  });

  test("CHAT_COMPLETION_REQUEST_FAILED 500", () => {
    const err = new MockHttpErrorResponse({
      status: 500,
      error: { error: { code: "CHAT_COMPLETION_REQUEST_FAILED", message: "Chat failed.", details: { cause: "AI Core 503" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("CHAT_COMPLETION_REQUEST_FAILED");
  });

  test("HARMONIZED_CHAT_FAILED 500", () => {
    const err = new MockHttpErrorResponse({
      status: 500,
      error: { error: { code: "HARMONIZED_CHAT_FAILED", message: "Harmonized chat failed.", details: { cause: "rate limit" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HARMONIZED_CHAT_FAILED");
  });
});

// ════════════════════════════════════════════════════════════════════
// Optional fields: target, innerError
// ════════════════════════════════════════════════════════════════════

describe("extractErrorDetail — optional fields", () => {
  test("preserves target field when present", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "CHAT_CONFIG_INVALID", message: "Bad config.", target: "modelName" } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.target).toBe("modelName");
  });

  test("preserves innerError field when present", () => {
    const err = new MockHttpErrorResponse({
      status: 500,
      error: { error: { code: "EMBEDDING_REQUEST_FAILED", message: "Upstream.", innerError: { code: "SDK_503", message: "AI Core unavailable" } } },
    });
    const detail = extractErrorDetail(err);
    expect(detail.innerError).toEqual({ code: "SDK_503", message: "AI Core unavailable" });
  });

  test("omits target when not present", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "CHAT_CONFIG_INVALID", message: "Missing field." } },
    });
    const detail = extractErrorDetail(err);
    expect(Object.keys(detail)).not.toContain("target");
  });

  test("omits details when not present", () => {
    const err = new MockHttpErrorResponse({
      status: 400,
      error: { error: { code: "CHAT_CONFIG_INVALID", message: "Missing field." } },
    });
    const detail = extractErrorDetail(err);
    expect(Object.keys(detail)).not.toContain("details");
  });

  test("omits innerError when not present", () => {
    const err = new MockHttpErrorResponse({
      status: 500,
      error: { error: { code: "EMBEDDING_REQUEST_FAILED", message: "Failed." } },
    });
    const detail = extractErrorDetail(err);
    expect(Object.keys(detail)).not.toContain("innerError");
  });
});

// ════════════════════════════════════════════════════════════════════
// Non-LLM HTTP errors
// ════════════════════════════════════════════════════════════════════

describe("extractErrorDetail — non-LLM HTTP errors", () => {
  test("401 without LLMErrorResponse body → HTTP_401", () => {
    const err = new MockHttpErrorResponse({ status: 401, statusText: "Unauthorized", error: "Unauthorized" });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_401");
    expect(detail.message).toBeTruthy();
  });

  test("403 without LLMErrorResponse body → HTTP_403", () => {
    const err = new MockHttpErrorResponse({ status: 403, error: "Forbidden" });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_403");
  });

  test("503 without LLMErrorResponse body → HTTP_503", () => {
    const err = new MockHttpErrorResponse({ status: 503, error: null });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_503");
  });

  test("body with missing error.code → HTTP_<status>", () => {
    const err = new MockHttpErrorResponse({ status: 400, error: { error: { message: "only message, no code" } } });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_400");
  });

  test("body with missing error.message → HTTP_<status>", () => {
    const err = new MockHttpErrorResponse({ status: 400, error: { error: { code: "SOMETHING" } } });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_400");
  });

  test("null body → HTTP_<status>", () => {
    const err = new MockHttpErrorResponse({ status: 500, error: null });
    const detail = extractErrorDetail(err);
    expect(detail.code).toBe("HTTP_500");
  });
});

// ════════════════════════════════════════════════════════════════════
// Network / non-HTTP errors
// ════════════════════════════════════════════════════════════════════

describe("extractErrorDetail — network and non-HTTP errors", () => {
  test("plain Error → NETWORK_ERROR", () => {
    const detail = extractErrorDetail(new Error("fetch failed"));
    expect(detail.code).toBe("NETWORK_ERROR");
    expect(detail.message).toBe("fetch failed");
  });

  test("TypeError → NETWORK_ERROR", () => {
    const detail = extractErrorDetail(new TypeError("Failed to fetch"));
    expect(detail.code).toBe("NETWORK_ERROR");
    expect(detail.message).toBe("Failed to fetch");
  });

  test("thrown string → UNKNOWN", () => {
    const detail = extractErrorDetail("something broke");
    expect(detail.code).toBe("UNKNOWN");
    expect(detail.message).toBe("An unexpected error occurred.");
  });

  test("thrown null → UNKNOWN", () => {
    const detail = extractErrorDetail(null);
    expect(detail.code).toBe("UNKNOWN");
  });

  test("thrown undefined → UNKNOWN", () => {
    const detail = extractErrorDetail(undefined);
    expect(detail.code).toBe("UNKNOWN");
  });

  test("thrown plain object → UNKNOWN", () => {
    const detail = extractErrorDetail({ foo: "bar" });
    expect(detail.code).toBe("UNKNOWN");
  });
});

// ════════════════════════════════════════════════════════════════════
// LLMErrorDetail shape contract
// ════════════════════════════════════════════════════════════════════

describe("LLMErrorDetail shape contract", () => {
  const cases = [
    new MockHttpErrorResponse({ status: 400, error: { error: { code: "X", message: "Y" } } }),
    new MockHttpErrorResponse({ status: 500, error: null }),
    new Error("test"),
    null,
    "string error",
  ];

  test.each(cases)("result always has code and message (case %#)", (input) => {
    const detail = extractErrorDetail(input);
    expect(typeof detail.code).toBe("string");
    expect(typeof detail.message).toBe("string");
    expect(detail.code.length).toBeGreaterThan(0);
    expect(detail.message.length).toBeGreaterThan(0);
  });

  test("result never contains stack trace", () => {
    const cases2 = [
      new MockHttpErrorResponse({ status: 500, error: null }),
      new Error("crash"),
      null,
    ];
    for (const input of cases2) {
      const detail = extractErrorDetail(input);
      const json = JSON.stringify(detail);
      expect(json).not.toContain("at Object.");
      expect(json).not.toContain(".js:");
    }
  });
});

// ════════════════════════════════════════════════════════════════════
// ErrorDisplayComponent — design mapping logic
// ════════════════════════════════════════════════════════════════════

// Re-implement the pure mapping logic from error-display.component.ts

const CODE_TO_DESIGN = {
  EMBEDDING_CONFIG_INVALID: "Critical",
  CHAT_CONFIG_INVALID: "Critical",
  INVALID_SEQUENCE_ID: "Critical",
  INVALID_ALGO_NAME: "Critical",
  UNSUPPORTED_FILTER_TYPE: "Critical",
  ENTITY_NOT_FOUND: "Information",
  SEQUENCE_COLUMN_NOT_FOUND: "Information",
  NETWORK_ERROR: "Critical",
  HTTP_401: "Critical",
  HTTP_403: "Critical",
};

function getDesign(code) {
  return CODE_TO_DESIGN[code] ?? "Negative";
}

function formatTitle(code) {
  return code
    .split("_")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

describe("ErrorDisplayComponent — design mapping", () => {
  test("config errors map to Critical", () => {
    expect(getDesign("EMBEDDING_CONFIG_INVALID")).toBe("Critical");
    expect(getDesign("CHAT_CONFIG_INVALID")).toBe("Critical");
    expect(getDesign("UNSUPPORTED_FILTER_TYPE")).toBe("Critical");
    expect(getDesign("INVALID_ALGO_NAME")).toBe("Critical");
  });

  test("not-found errors map to Information", () => {
    expect(getDesign("ENTITY_NOT_FOUND")).toBe("Information");
    expect(getDesign("SEQUENCE_COLUMN_NOT_FOUND")).toBe("Information");
  });

  test("upstream/SDK errors default to Negative", () => {
    expect(getDesign("EMBEDDING_REQUEST_FAILED")).toBe("Negative");
    expect(getDesign("CHAT_COMPLETION_REQUEST_FAILED")).toBe("Negative");
    expect(getDesign("HARMONIZED_CHAT_FAILED")).toBe("Negative");
    expect(getDesign("UNKNOWN")).toBe("Negative");
  });

  test("HTTP auth errors map to Critical", () => {
    expect(getDesign("HTTP_401")).toBe("Critical");
    expect(getDesign("HTTP_403")).toBe("Critical");
  });

  test("NETWORK_ERROR maps to Critical", () => {
    expect(getDesign("NETWORK_ERROR")).toBe("Critical");
  });

  test("unknown code defaults to Negative", () => {
    expect(getDesign("SOME_FUTURE_CODE")).toBe("Negative");
  });
});

describe("ErrorDisplayComponent — title formatting", () => {
  test("formats EMBEDDING_CONFIG_INVALID correctly", () => {
    expect(formatTitle("EMBEDDING_CONFIG_INVALID")).toBe("Embedding Config Invalid");
  });

  test("formats CHAT_CONFIG_INVALID correctly", () => {
    expect(formatTitle("CHAT_CONFIG_INVALID")).toBe("Chat Config Invalid");
  });

  test("formats ENTITY_NOT_FOUND correctly", () => {
    expect(formatTitle("ENTITY_NOT_FOUND")).toBe("Entity Not Found");
  });

  test("formats UNKNOWN correctly", () => {
    expect(formatTitle("UNKNOWN")).toBe("Unknown");
  });

  test("formats NETWORK_ERROR correctly", () => {
    expect(formatTitle("NETWORK_ERROR")).toBe("Network Error");
  });

  test("formats HTTP_401 correctly", () => {
    expect(formatTitle("HTTP_401")).toBe("Http 401");
  });
});
