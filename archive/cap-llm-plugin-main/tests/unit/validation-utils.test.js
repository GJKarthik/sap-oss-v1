// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const {
  validateSqlIdentifier,
  validatePositiveInteger,
  validateEmbeddingVector,
} = require("../../lib/validation-utils");

describe("validateSqlIdentifier", () => {
  test("accepts valid simple identifier", () => {
    expect(() => validateSqlIdentifier("MY_TABLE", "test")).not.toThrow();
  });

  test("accepts identifier starting with underscore", () => {
    expect(() => validateSqlIdentifier("_col1", "test")).not.toThrow();
  });

  test("accepts identifier with hyphens", () => {
    expect(() => validateSqlIdentifier("my-table", "test")).not.toThrow();
  });

  test("accepts mixed case alphanumeric", () => {
    expect(() => validateSqlIdentifier("MyTable123", "test")).not.toThrow();
  });

  test("rejects empty string", () => {
    expect(() => validateSqlIdentifier("", "tableName")).toThrow(/Invalid tableName: must be a non-empty string/);
  });

  test("rejects non-string (number)", () => {
    expect(() => validateSqlIdentifier(123, "tableName")).toThrow(/Invalid tableName: must be a non-empty string/);
  });

  test("rejects non-string (null)", () => {
    expect(() => validateSqlIdentifier(null, "tableName")).toThrow(/Invalid tableName: must be a non-empty string/);
  });

  test("rejects non-string (undefined)", () => {
    expect(() => validateSqlIdentifier(undefined, "tableName")).toThrow(
      /Invalid tableName: must be a non-empty string/
    );
  });

  test("rejects identifier with semicolon (SQL injection)", () => {
    expect(() => validateSqlIdentifier("table; DROP TABLE users --", "tableName")).toThrow(
      /contains characters that are not allowed/
    );
  });

  test("rejects identifier with single quote", () => {
    expect(() => validateSqlIdentifier("table'name", "col")).toThrow(/contains characters that are not allowed/);
  });

  test("rejects identifier with double quote", () => {
    expect(() => validateSqlIdentifier('table"name', "col")).toThrow(/contains characters that are not allowed/);
  });

  test("rejects identifier with spaces", () => {
    expect(() => validateSqlIdentifier("my table", "col")).toThrow(/contains characters that are not allowed/);
  });

  test("rejects identifier with parentheses", () => {
    expect(() => validateSqlIdentifier("func()", "col")).toThrow(/contains characters that are not allowed/);
  });

  test("rejects identifier starting with a digit", () => {
    expect(() => validateSqlIdentifier("1table", "col")).toThrow(/contains characters that are not allowed/);
  });
});

describe("validatePositiveInteger", () => {
  test("accepts positive integer", () => {
    expect(() => validatePositiveInteger(5, "topK")).not.toThrow();
  });

  test("accepts 1", () => {
    expect(() => validatePositiveInteger(1, "topK")).not.toThrow();
  });

  test("accepts value at max boundary", () => {
    expect(() => validatePositiveInteger(10000, "topK")).not.toThrow();
  });

  test("rejects 0", () => {
    expect(() => validatePositiveInteger(0, "topK")).toThrow(/must be a positive integer/);
  });

  test("rejects negative integer", () => {
    expect(() => validatePositiveInteger(-1, "topK")).toThrow(/must be a positive integer/);
  });

  test("rejects float", () => {
    expect(() => validatePositiveInteger(3.5, "topK")).toThrow(/must be a positive integer/);
  });

  test("rejects string", () => {
    expect(() => validatePositiveInteger("5", "topK")).toThrow(/must be a positive integer/);
  });

  test("rejects value exceeding max", () => {
    expect(() => validatePositiveInteger(10001, "topK")).toThrow(/exceeds maximum allowed value/);
  });

  test("respects custom max", () => {
    expect(() => validatePositiveInteger(50, "topK", 100)).not.toThrow();
    expect(() => validatePositiveInteger(101, "topK", 100)).toThrow(/exceeds maximum allowed value of 100/);
  });

  test("rejects SQL injection string", () => {
    expect(() => validatePositiveInteger("1; DROP TABLE --", "topK")).toThrow(/must be a positive integer/);
  });
});

describe("validateEmbeddingVector", () => {
  test("accepts valid numeric array", () => {
    expect(() => validateEmbeddingVector([0.1, 0.2, -0.3, 0.0])).not.toThrow();
  });

  test("accepts single-element array", () => {
    expect(() => validateEmbeddingVector([1.0])).not.toThrow();
  });

  test("accepts integers", () => {
    expect(() => validateEmbeddingVector([1, 2, 3])).not.toThrow();
  });

  test("rejects empty array", () => {
    expect(() => validateEmbeddingVector([])).toThrow(/must be a non-empty array/);
  });

  test("rejects non-array (string)", () => {
    expect(() => validateEmbeddingVector("not an array")).toThrow(/must be a non-empty array/);
  });

  test("rejects non-array (null)", () => {
    expect(() => validateEmbeddingVector(null)).toThrow(/must be a non-empty array/);
  });

  test("rejects array with non-number element", () => {
    expect(() => validateEmbeddingVector([0.1, "bad", 0.3])).toThrow(/element at index 1 is not a finite number/);
  });

  test("rejects array with NaN", () => {
    expect(() => validateEmbeddingVector([0.1, NaN, 0.3])).toThrow(/element at index 1 is not a finite number/);
  });

  test("rejects array with Infinity", () => {
    expect(() => validateEmbeddingVector([0.1, Infinity])).toThrow(/element at index 1 is not a finite number/);
  });

  test("rejects array with -Infinity", () => {
    expect(() => validateEmbeddingVector([0.1, -Infinity])).toThrow(/element at index 1 is not a finite number/);
  });
});

// =============================================================================
// assessGroundingViaLLM
// =============================================================================

const { assessGroundingViaLLM, assessResponseQuality } = require("../../lib/validation-utils");

describe("assessGroundingViaLLM", () => {
  // Helper: mock chat function that returns decomposed claims then NLI verdicts
  function mockChatFn(decomposeResponse, nliResponse) {
    let callCount = 0;
    return async (msgs) => {
      callCount++;
      const userMsg = msgs.find((m) => m.role === "user")?.content || "";
      if (userMsg.includes("Decompose") || userMsg.includes("<text>")) {
        return typeof decomposeResponse === "function" ? decomposeResponse() : decomposeResponse;
      }
      return typeof nliResponse === "function" ? nliResponse() : nliResponse;
    };
  }

  test("returns fallback with checkCompleted=false for empty input", async () => {
    const result = await assessGroundingViaLLM("", [], null);
    expect(result.checkCompleted).toBe(false);
    expect(result.faithfulnessScore).toBe(0);
    expect(result.claims).toEqual([]);
    expect(result.contradictions).toEqual([]);
    expect(result.unsupported).toEqual([]);
  });

  test("returns fallback for missing context docs", async () => {
    const result = await assessGroundingViaLLM("Some response text.", [], async () => "[]");
    expect(result.checkCompleted).toBe(false);
  });

  test("returns fallback when chatFn is not a function", async () => {
    const result = await assessGroundingViaLLM("Some text", ["context"], "not a function");
    expect(result.checkCompleted).toBe(false);
  });

  test("returns checkCompleted=true on successful evaluation", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["SAP HANA supports vector search."]),
      JSON.stringify([{ claim: "SAP HANA supports vector search.", verdict: "SUPPORTED", confidence: 0.95, evidence: "stated in context" }])
    );
    const result = await assessGroundingViaLLM("SAP HANA supports vector search.", ["SAP HANA supports vector search"], chatFn);
    expect(result.checkCompleted).toBe(true);
    expect(result.faithfulnessScore).toBeGreaterThan(0);
    expect(result.claims).toHaveLength(1);
    expect(result.claims[0].verdict).toBe("SUPPORTED");
  });

  test("correctly scores PARTIALLY_SUPPORTED claims", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["HANA uses cosine."]),
      JSON.stringify([{ claim: "HANA uses cosine.", verdict: "PARTIALLY_SUPPORTED", confidence: 0.6, evidence: "partially matches" }])
    );
    const result = await assessGroundingViaLLM("HANA uses cosine.", ["HANA supports cosine similarity"], chatFn);
    expect(result.checkCompleted).toBe(true);
    expect(result.faithfulnessScore).toBeGreaterThan(0);
    expect(result.faithfulnessScore).toBeLessThan(1);
  });

  test("detects contradictions and populates contradictions array", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["HANA supports 50000 results."]),
      JSON.stringify([{ claim: "HANA supports 50000 results.", verdict: "CONTRADICTED", confidence: 0.9, evidence: "context says 10000" }])
    );
    const result = await assessGroundingViaLLM("HANA supports 50000 results.", ["Max 10000 results per query"], chatFn);
    expect(result.contradictions).toHaveLength(1);
    expect(result.contradictions[0].claim).toContain("50000");
    expect(result.faithfulnessScore).toBe(0);
  });

  test("detects NOT_SUPPORTED claims and populates unsupported array", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["HANA was released in 2010."]),
      JSON.stringify([{ claim: "HANA was released in 2010.", verdict: "NOT_SUPPORTED", confidence: 0.1, evidence: "not in context" }])
    );
    const result = await assessGroundingViaLLM("HANA was released in 2010.", ["HANA supports vector search"], chatFn);
    expect(result.unsupported).toHaveLength(1);
    expect(result.faithfulnessScore).toBe(0);
  });

  test("handles malformed JSON from LLM (wrapped in text)", async () => {
    const chatFn = mockChatFn(
      'Sure! Here are the claims: ["Claim one is long enough to pass."]',
      'Here is the result: [{"claim":"Claim one is long enough to pass.","verdict":"SUPPORTED","confidence":0.8,"evidence":"ok"}]'
    );
    const result = await assessGroundingViaLLM("Claim one is long enough to pass.", ["context"], chatFn);
    expect(result.checkCompleted).toBe(true);
    expect(result.claims).toHaveLength(1);
  });

  test("returns fallback when LLM throws an error", async () => {
    const chatFn = async () => { throw new Error("LLM down"); };
    const result = await assessGroundingViaLLM("Some response text that is long enough to process.", ["context"], chatFn);
    expect(result.checkCompleted).toBe(false);
    expect(result.faithfulnessScore).toBe(0);
  });

  test("clamps confidence values to [0, 1]", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["A claim that is long enough."]),
      JSON.stringify([{ claim: "A claim that is long enough.", verdict: "SUPPORTED", confidence: 5.0, evidence: "test" }])
    );
    const result = await assessGroundingViaLLM("A claim that is long enough.", ["context"], chatFn);
    expect(result.claims[0].confidence).toBeLessThanOrEqual(1);
    expect(result.claims[0].confidence).toBeGreaterThanOrEqual(0);
  });

  test("filters out claims with invalid verdicts", async () => {
    const chatFn = mockChatFn(
      JSON.stringify(["Valid claim is long enough.", "Another valid claim here."]),
      JSON.stringify([
        { claim: "Valid claim is long enough.", verdict: "SUPPORTED", confidence: 0.9, evidence: "ok" },
        { claim: "Another valid claim here.", verdict: "INVALID_VERDICT", confidence: 0.5, evidence: "bad" },
      ])
    );
    const result = await assessGroundingViaLLM("Valid claim is long enough. Another valid claim here.", ["context"], chatFn);
    expect(result.claims).toHaveLength(1);
    expect(result.claims[0].verdict).toBe("SUPPORTED");
  });

  test("handles SDK response object with getContent()", async () => {
    const sdkResponse = { getContent: () => "This is a response that is long enough." };
    const chatFn = mockChatFn(
      JSON.stringify(["This is a response that is long enough."]),
      JSON.stringify([{ claim: "This is a response that is long enough.", verdict: "SUPPORTED", confidence: 0.9, evidence: "ok" }])
    );
    const result = await assessGroundingViaLLM(sdkResponse, ["context docs"], chatFn);
    expect(result.checkCompleted).toBe(true);
  });
});

// =============================================================================
// assessResponseQuality
// =============================================================================

describe("assessResponseQuality", () => {
  test("returns hasContent=false for empty response", () => {
    const result = assessResponseQuality("", []);
    expect(result.hasContent).toBe(false);
    expect(result.contentLength).toBe(0);
    expect(result.warnings).toContain("LLM returned empty response");
  });

  test("returns hasContent=true for non-empty response", () => {
    const result = assessResponseQuality("Hello world", []);
    expect(result.hasContent).toBe(true);
    expect(result.contentLength).toBe(11);
    expect(result.estimatedTokens).toBe(3);
  });

  test("detects context grounding via word overlap", () => {
    const context = ["SAP HANA Cloud supports vector similarity search with cosine distance"];
    const response = "SAP HANA Cloud provides vector similarity search capabilities using cosine distance metrics";
    const result = assessResponseQuality(response, context);
    expect(result.usedContext).toBe(true);
  });

  test("warns when response is not grounded in context", () => {
    const context = ["SAP HANA Cloud supports vector similarity search with cosine distance metrics and advanced algorithms"];
    const response = "The weather today is sunny and warm";
    const result = assessResponseQuality(response, context);
    expect(result.usedContext).toBe(false);
  });

  test("handles SDK response object with getContent()", () => {
    const sdkResponse = { getContent: () => "Hello from SDK" };
    const result = assessResponseQuality(sdkResponse, []);
    expect(result.hasContent).toBe(true);
    expect(result.contentLength).toBe(14);
  });
});
