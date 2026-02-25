/**
 * SQL identifier validation regex.
 * Allows: letters, digits, underscores, hyphens.
 * Must start with a letter or underscore.
 * Prevents SQL injection in identifier positions (table names, column names, view names).
 */
const VALID_SQL_IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_-]*$/;

/**
 * Validates that a string is a safe SQL identifier.
 * Throws an error if the identifier contains characters that could enable SQL injection.
 *
 * @param {string} name - The identifier to validate.
 * @param {string} label - A human-readable label for error messages (e.g., "tableName", "columnName").
 * @throws {Error} If the identifier is not a valid SQL identifier.
 */
function validateSqlIdentifier(name, label) {
  if (typeof name !== "string" || name.length === 0) {
    throw new Error(`Invalid ${label}: must be a non-empty string. Received: ${typeof name}`);
  }
  if (!VALID_SQL_IDENTIFIER.test(name)) {
    throw new Error(
      `Invalid ${label}: "${name}" contains characters that are not allowed in SQL identifiers. ` +
        `Only letters, digits, underscores, and hyphens are permitted, and it must start with a letter or underscore.`
    );
  }
}

/**
 * Validates that a value is a positive integer within a reasonable range.
 *
 * @param {*} value - The value to validate.
 * @param {string} label - A human-readable label for error messages.
 * @param {number} [max=10000] - Maximum allowed value.
 * @throws {Error} If the value is not a positive integer or exceeds max.
 */
function validatePositiveInteger(value, label, max = 10000) {
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid ${label}: must be a positive integer. Received: ${value}`);
  }
  if (value > max) {
    throw new Error(`Invalid ${label}: ${value} exceeds maximum allowed value of ${max}.`);
  }
}

/**
 * Validates that an embedding is a non-empty array of finite numbers.
 *
 * @param {*} embedding - The embedding to validate.
 * @throws {Error} If the embedding is not a valid numeric array.
 */
function validateEmbeddingVector(embedding) {
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error(
      "Invalid embedding: must be a non-empty array. Received: " +
        (Array.isArray(embedding) ? "empty array" : typeof embedding)
    );
  }
  for (let i = 0; i < embedding.length; i++) {
    if (typeof embedding[i] !== "number" || !isFinite(embedding[i])) {
      throw new Error(`Invalid embedding: element at index ${i} is not a finite number. Received: ${embedding[i]}`);
    }
  }
}

module.exports = {
  validateSqlIdentifier,
  validatePositiveInteger,
  validateEmbeddingVector,
};
