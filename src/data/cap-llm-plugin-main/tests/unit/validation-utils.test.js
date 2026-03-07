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
