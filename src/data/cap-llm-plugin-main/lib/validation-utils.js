// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
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

/**
 * Known embedding model dimensions.
 * Prevents model-mismatch bugs where query and index use different models.
 * Covers OpenAI, Cohere, Voyage, and common open-source models used with SAP AI Core.
 */
const EMBEDDING_MODEL_DIMENSIONS = {
  // OpenAI
  "text-embedding-ada-002": 1536,
  "text-embedding-3-small": 1536,
  "text-embedding-3-large": 3072,
  // OpenAI with custom dimensions
  "text-embedding-3-small-256": 256,
  "text-embedding-3-small-512": 512,
  // Cohere
  "embed-english-v3.0": 1024,
  "embed-multilingual-v3.0": 1024,
  "embed-english-light-v3.0": 384,
  "embed-multilingual-light-v3.0": 384,
  // Voyage
  "voyage-large-2": 1536,
  "voyage-code-2": 1536,
  "voyage-2": 1024,
  // BGE (common open-source, used via SAP AI Core)
  "bge-large-en-v1.5": 1024,
  "bge-base-en-v1.5": 768,
  "bge-small-en-v1.5": 384,
};

/**
 * Validate that embedding dimensions match the expected model output.
 * Logs a warning (not error) for unknown models.
 *
 * @param {number[]} embedding - The embedding vector.
 * @param {string} modelName - The model name used to generate the embedding.
 * @throws {Error} If dimensions don't match expected output for a known model.
 */
function validateEmbeddingDimensions(embedding, modelName) {
  const expectedDims = EMBEDDING_MODEL_DIMENSIONS[modelName];
  if (expectedDims && embedding.length !== expectedDims) {
    throw new Error(
      `Embedding dimension mismatch: model "${modelName}" produces ${expectedDims}-dim vectors, ` +
      `but received ${embedding.length} dimensions. Ensure the same model is used for indexing and querying.`
    );
  }
}

/**
 * Validates that an LLM response contains content and is not empty.
 * Returns a quality assessment object.
 *
 * @param {*} response - The LLM response object or string.
 * @param {string[]} context - Array of context document strings used in the prompt.
 * @returns {{ hasContent: boolean, contentLength: number, estimatedTokens: number, usedContext: boolean, warnings: string[] }}
 */
function assessResponseQuality(response, context) {
  const assessment = {
    hasContent: false,
    contentLength: 0,
    estimatedTokens: 0,
    usedContext: false,
    warnings: [],
  };

  const content = typeof response === "string"
    ? response
    : response?.getContent?.() ?? response?.choices?.[0]?.message?.content ?? "";

  assessment.hasContent = content.length > 0;
  assessment.contentLength = content.length;
  assessment.estimatedTokens = Math.ceil(content.length / 4);

  if (content.length === 0) {
    assessment.warnings.push("LLM returned empty response");
  }

  // Check if response references provided context (grounding check using bigram + keyword overlap)
  if (context && context.length > 0) {
    const normalize = (s) => s.toLowerCase().replace(/[^\w\s]/g, "");
    const contextNorm = normalize(context.join(" "));
    const responseNorm = normalize(content);

    // Keyword overlap (words > 4 chars, filters stopwords by length)
    const contextWords = new Set(contextNorm.split(/\s+/).filter(w => w.length > 4));
    const responseWords = responseNorm.split(/\s+/).filter(w => w.length > 4);
    let wordOverlap = 0;
    for (const word of responseWords) {
      if (contextWords.has(word)) wordOverlap++;
    }

    // Bigram overlap (catches multi-word phrases, more robust than single words)
    const toBigrams = (words) => {
      const bigrams = new Set();
      for (let i = 0; i < words.length - 1; i++) {
        bigrams.add(words[i] + " " + words[i + 1]);
      }
      return bigrams;
    };
    const contextBigrams = toBigrams(contextNorm.split(/\s+/).filter(w => w.length > 2));
    const responseBigramList = responseNorm.split(/\s+/).filter(w => w.length > 2);
    let bigramOverlap = 0;
    for (let i = 0; i < responseBigramList.length - 1; i++) {
      if (contextBigrams.has(responseBigramList[i] + " " + responseBigramList[i + 1])) {
        bigramOverlap++;
      }
    }

    // Grounded if: significant keyword overlap OR any bigram matches (stronger signal)
    assessment.usedContext = wordOverlap > 3 || bigramOverlap > 1;
    assessment.groundingDetail = { wordOverlap, bigramOverlap };
    if (!assessment.usedContext && contextWords.size > 10) {
      assessment.warnings.push("Response may not be grounded in provided context");
    }
  }

  return assessment;
}

/**
 * LLM-as-judge NLI grounding assessment.
 *
 * Splits the response into claims (sentences), sends a single batched prompt
 * to the LLM asking it to classify each claim as SUPPORTED, NOT_SUPPORTED,
 * or CONTRADICTED relative to the provided context documents.
 *
 * @param {string} responseText - The LLM response text to evaluate.
 * @param {string[]} contextDocs - Array of context document strings.
 * @param {(messages: Array<{role: string, content: string}>) => Promise<string>} chatFn
 *   Callback that sends messages to an LLM and returns the content string.
 * @returns {Promise<{faithfulnessScore: number, claims: Array<{claim: string, verdict: string, evidence: string}>, contradictions: Array<{claim: string, evidence: string}>}>}
 */
async function assessGroundingViaLLM(responseText, contextDocs, chatFn) {
  const fallback = { faithfulnessScore: 0, claims: [], contradictions: [] };

  if (!responseText || !contextDocs || contextDocs.length === 0 || typeof chatFn !== "function") {
    return fallback;
  }

  // Extract text content from response (handle SDK response objects)
  const content = typeof responseText === "string"
    ? responseText
    : responseText?.getContent?.() ?? responseText?.choices?.[0]?.message?.content ?? "";

  if (!content) return fallback;

  // Split into claims (sentences)
  const claims = content
    .split(/(?<=[.!?])\s+/)
    .map(s => s.trim())
    .filter(s => s.length > 10); // Filter trivial fragments

  if (claims.length === 0) return fallback;

  const contextBlock = contextDocs.map((doc, i) => `[Document ${i + 1}]\n${doc}`).join("\n\n");
  const claimsList = claims.map((c, i) => `${i + 1}. ${c}`).join("\n");

  const prompt = `You are a fact-checking judge. Given ONLY the following context, classify each claim as SUPPORTED, NOT_SUPPORTED, or CONTRADICTED.

Context:
${contextBlock}

Claims:
${claimsList}

Respond as a JSON array: [{"claim": "...", "verdict": "SUPPORTED|NOT_SUPPORTED|CONTRADICTED", "evidence": "brief quote or reason"}]
Return ONLY the JSON array, no other text.`;

  try {
    const llmResponse = await chatFn([
      { role: "system", content: "You are a precise fact-checking assistant. Output only valid JSON." },
      { role: "user", content: prompt },
    ]);

    // Parse JSON response with fallback to regex extraction
    let parsed;
    try {
      parsed = JSON.parse(llmResponse);
    } catch {
      // Try to extract JSON array from response text
      const match = llmResponse.match(/\[[\s\S]*\]/);
      if (match) {
        try {
          parsed = JSON.parse(match[0]);
        } catch {
          return fallback;
        }
      } else {
        return fallback;
      }
    }

    if (!Array.isArray(parsed)) return fallback;

    const validVerdicts = new Set(["SUPPORTED", "NOT_SUPPORTED", "CONTRADICTED"]);
    const validatedClaims = parsed
      .filter(c => c && typeof c.claim === "string" && validVerdicts.has(c.verdict))
      .map(c => ({
        claim: c.claim,
        verdict: c.verdict,
        evidence: c.evidence || "",
      }));

    if (validatedClaims.length === 0) return fallback;

    const supportedCount = validatedClaims.filter(c => c.verdict === "SUPPORTED").length;
    const contradictions = validatedClaims
      .filter(c => c.verdict === "CONTRADICTED")
      .map(c => ({ claim: c.claim, evidence: c.evidence }));

    return {
      faithfulnessScore: supportedCount / validatedClaims.length,
      claims: validatedClaims,
      contradictions,
    };
  } catch {
    return fallback;
  }
}

module.exports = {
  validateSqlIdentifier,
  validatePositiveInteger,
  validateEmbeddingVector,
  EMBEDDING_MODEL_DIMENSIONS,
  validateEmbeddingDimensions,
  assessResponseQuality,
  assessGroundingViaLLM,
};
