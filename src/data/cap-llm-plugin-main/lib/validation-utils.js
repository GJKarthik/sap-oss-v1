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
 * Maximum character budget for the grounding prompt (context + claims).
 * Prevents exceeding model context windows. ~3000 tokens * 4 chars/token.
 */
const GROUNDING_MAX_PROMPT_CHARS = 12000;

/**
 * Extract text content from an LLM response (string, SDK response object, or OpenAI format).
 * @param {*} response
 * @returns {string}
 */
function _extractContent(response) {
  if (typeof response === "string") return response;
  return response?.getContent?.() ?? response?.choices?.[0]?.message?.content ?? "";
}

/**
 * Parse a JSON array from an LLM response string.
 * Tries direct parse first, then non-greedy bracket extraction, then greedy.
 * @param {string} text
 * @returns {Array|null}
 */
function _parseJSONArray(text) {
  if (!text || typeof text !== "string") return null;
  // Direct parse
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed;
  } catch { /* fall through */ }
  // Non-greedy extraction: find first [ ... ] that parses
  const nonGreedy = text.match(/\[[\s\S]*?\]/g);
  if (nonGreedy) {
    for (const candidate of nonGreedy) {
      try {
        const parsed = JSON.parse(candidate);
        if (Array.isArray(parsed)) return parsed;
      } catch { /* try next */ }
    }
  }
  // Greedy fallback (outermost brackets)
  const greedy = text.match(/\[[\s\S]*\]/);
  if (greedy) {
    try {
      const parsed = JSON.parse(greedy[0]);
      if (Array.isArray(parsed)) return parsed;
    } catch { /* give up */ }
  }
  return null;
}

/**
 * Decompose a response into atomic, independently verifiable claims using an LLM.
 *
 * Unlike regex sentence splitting, this handles abbreviations ("Dr.", "3.5"),
 * compound claims ("X supports A and B"), and filters non-factual content
 * (greetings, hedges, meta-commentary).
 *
 * @param {string} content - The response text to decompose.
 * @param {(messages: Array<{role: string, content: string}>) => Promise<string>} chatFn
 * @returns {Promise<string[]>} Array of atomic claim strings.
 */
async function _decomposeClaims(content, chatFn) {
  // Budget guard: if content is very short, skip the LLM call
  if (content.length < 40) return [content];

  // Truncate to budget
  const truncated = content.length > GROUNDING_MAX_PROMPT_CHARS / 2
    ? content.slice(0, GROUNDING_MAX_PROMPT_CHARS / 2)
    : content;

  const prompt = `Decompose the following text into atomic, independently verifiable factual claims.

Rules:
- Each claim must be a single, self-contained factual statement
- Split compound sentences ("X does A and B") into separate claims
- Omit greetings, hedges ("I think"), meta-commentary ("As mentioned above"), and questions
- Omit claims that are purely subjective opinions with no factual component
- Preserve specific numbers, names, and technical terms exactly

Text:
${truncated}

Return a JSON array of strings, each being one atomic claim. Example:
["SAP HANA supports vector similarity search.", "The default algorithm is cosine similarity.", "Up to 10000 results can be returned."]`;

  try {
    const response = await chatFn([
      { role: "system", content: "You decompose text into atomic factual claims. Output only a JSON array of strings." },
      { role: "user", content: prompt },
    ]);
    const parsed = _parseJSONArray(response);
    if (parsed && parsed.length > 0 && parsed.every(c => typeof c === "string")) {
      return parsed.filter(c => c.trim().length > 10);
    }
  } catch { /* fall through to regex fallback */ }

  // Fallback: improved regex that avoids splitting on abbreviations and decimals
  // Negative lookbehind for common abbreviations and decimal numbers
  return content
    .split(/(?<![A-Z][a-z]?)(?<!\d)(?<=[.!?])\s+(?=[A-Z"])/)
    .map(s => s.trim())
    .filter(s => s.length > 10);
}

/**
 * LLM-as-judge NLI grounding assessment.
 *
 * Two-phase approach:
 * 1. Decompose response into atomic claims via LLM (handles abbreviations,
 *    compound sentences, filters non-factual content)
 * 2. Classify each claim as SUPPORTED / NOT_SUPPORTED / CONTRADICTED
 *    with confidence scores via a separate LLM call with few-shot examples
 *
 * @param {*} responseText - The LLM response (string or SDK response object).
 * @param {string[]} contextDocs - Array of context document strings.
 * @param {(messages: Array<{role: string, content: string}>) => Promise<string>} chatFn
 *   Callback for the NLI judge model. Should be a different model than the generator
 *   to avoid self-judge bias. The caller controls which model this routes to.
 * @returns {Promise<{faithfulnessScore: number, claims: Array<{claim: string, verdict: string, confidence: number, evidence: string}>, contradictions: Array<{claim: string, evidence: string}>, unsupported: Array<{claim: string, evidence: string}>}>}
 */
async function assessGroundingViaLLM(responseText, contextDocs, chatFn) {
  const fallback = { faithfulnessScore: 0, claims: [], contradictions: [], unsupported: [] };

  if (!responseText || !contextDocs || contextDocs.length === 0 || typeof chatFn !== "function") {
    return fallback;
  }

  const content = _extractContent(responseText);
  if (!content) return fallback;

  // Phase 1: LLM-based claim decomposition
  const claims = await _decomposeClaims(content, chatFn);
  if (claims.length === 0) return fallback;

  // Phase 2: NLI classification with few-shot examples and confidence scoring
  // Budget guard: truncate context to fit within prompt limits
  let contextBlock = "";
  let contextBudget = GROUNDING_MAX_PROMPT_CHARS;
  for (let i = 0; i < contextDocs.length; i++) {
    const docHeader = `[Document ${i + 1}]\n`;
    const docContent = contextDocs[i] || "";
    const docText = docHeader + docContent;
    if (contextBudget - docText.length < 0) {
      // Truncate this doc to fit remaining budget
      if (contextBudget > docHeader.length + 50) {
        contextBlock += docHeader + docContent.slice(0, contextBudget - docHeader.length) + "...\n\n";
      }
      break;
    }
    contextBlock += docText + "\n\n";
    contextBudget -= docText.length + 2;
  }

  const claimsList = claims.map((c, i) => `${i + 1}. ${c}`).join("\n");

  const prompt = `You are an expert NLI (Natural Language Inference) judge. Given ONLY the context below, classify each claim.

## Verdicts
- SUPPORTED: The claim is directly entailed by the context (confidence 0.8-1.0)
- PARTIALLY_SUPPORTED: The claim is mostly correct but has minor inaccuracies or missing qualifiers (confidence 0.4-0.7)
- NOT_SUPPORTED: The claim cannot be verified from the context — it may be true but is not grounded (confidence 0.0-0.3)
- CONTRADICTED: The claim directly conflicts with information in the context (confidence 0.8-1.0 for the contradiction)

## Context
${contextBlock}
## Claims
${claimsList}

## Examples
Context: "SAP HANA Cloud supports cosine similarity and L2 distance for vector search. Maximum 10000 results per query."
Claim: "SAP HANA supports cosine similarity search."
→ {"claim":"SAP HANA supports cosine similarity search.","verdict":"SUPPORTED","confidence":0.95,"evidence":"Context states 'supports cosine similarity'"}

Claim: "SAP HANA supports up to 50000 results."
→ {"claim":"SAP HANA supports up to 50000 results.","verdict":"CONTRADICTED","confidence":0.9,"evidence":"Context says maximum 10000, not 50000"}

Claim: "SAP HANA was released in 2010."
→ {"claim":"SAP HANA was released in 2010.","verdict":"NOT_SUPPORTED","confidence":0.1,"evidence":"Release date not mentioned in context"}

Claim: "SAP HANA supports vector search with multiple algorithms."
→ {"claim":"SAP HANA supports vector search with multiple algorithms.","verdict":"PARTIALLY_SUPPORTED","confidence":0.6,"evidence":"Context mentions two algorithms but claim implies more"}

## Output
Return ONLY a JSON array:
[{"claim":"...","verdict":"SUPPORTED|PARTIALLY_SUPPORTED|NOT_SUPPORTED|CONTRADICTED","confidence":0.0-1.0,"evidence":"brief quote or explanation"}]`;

  try {
    const llmResponse = await chatFn([
      { role: "system", content: "You are an NLI judge. Output only valid JSON. Be strict: if the context does not explicitly support a claim, mark it NOT_SUPPORTED even if it seems plausible." },
      { role: "user", content: prompt },
    ]);

    const parsed = _parseJSONArray(llmResponse);
    if (!parsed) return fallback;

    const validVerdicts = new Set(["SUPPORTED", "PARTIALLY_SUPPORTED", "NOT_SUPPORTED", "CONTRADICTED"]);
    const validatedClaims = parsed
      .filter(c => c && typeof c.claim === "string" && validVerdicts.has(c.verdict))
      .map(c => ({
        claim: c.claim,
        verdict: c.verdict,
        confidence: typeof c.confidence === "number" ? Math.max(0, Math.min(1, c.confidence)) : 0.5,
        evidence: c.evidence || "",
      }));

    if (validatedClaims.length === 0) return fallback;

    // Weighted faithfulness: SUPPORTED=1.0, PARTIALLY_SUPPORTED=0.5, others=0
    let weightedSum = 0;
    let totalWeight = 0;
    for (const c of validatedClaims) {
      const weight = c.confidence;
      if (c.verdict === "SUPPORTED") {
        weightedSum += 1.0 * weight;
      } else if (c.verdict === "PARTIALLY_SUPPORTED") {
        weightedSum += 0.5 * weight;
      }
      // NOT_SUPPORTED and CONTRADICTED contribute 0
      totalWeight += weight;
    }
    const faithfulnessScore = totalWeight > 0 ? weightedSum / totalWeight : 0;

    const contradictions = validatedClaims
      .filter(c => c.verdict === "CONTRADICTED")
      .map(c => ({ claim: c.claim, evidence: c.evidence }));

    const unsupported = validatedClaims
      .filter(c => c.verdict === "NOT_SUPPORTED")
      .map(c => ({ claim: c.claim, evidence: c.evidence }));

    return { faithfulnessScore, claims: validatedClaims, contradictions, unsupported };
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
