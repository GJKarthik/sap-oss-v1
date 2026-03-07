"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const cds = __importStar(require("@sap/cds"));
const InvalidSimilaritySearchAlgoNameError = require("./errors/InvalidSimilaritySearchAlgoNameError");
const validation_utils_1 = require("../lib/validation-utils");
const legacy = __importStar(require("./legacy"));
const AnonymizationError_1 = require("../src/errors/AnonymizationError");
const EmbeddingError_1 = require("../src/errors/EmbeddingError");
const ChatCompletionError_1 = require("../src/errors/ChatCompletionError");
const tracer_1 = require("../src/telemetry/tracer");
const ai_sdk_middleware_1 = require("../src/telemetry/ai-sdk-middleware");
const LOG = cds.log("cap-llm-plugin");
// ════════════════════════════════════════════════════════════════════
class CAPLLMPlugin extends cds.Service {
    async init() {
        await super.init();
    }
    /**
     * Retrieve anonymized data for a given entity from its HANA anonymized view.
     *
     * The entity must have `@anonymize` annotations in its CDS model, and the
     * anonymized view must have been created by the plugin's `served` handler.
     *
     * @param entityName - Fully qualified entity name in `"<ServiceName>.<EntityName>"` format.
     * @param sequenceIds - Optional sequence IDs to filter results. Default is `[]` (all rows).
     * @returns The anonymized rows from the HANA anonymized view.
     * @throws {Error} If the entity is not found in CDS services.
     * @throws {Error} If no `is_sequence` column is defined on the entity.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const data = await plugin.getAnonymizedData("EmployeeService.Employees", [1001, 1002]);
     * ```
     */
    async getAnonymizedData(entityName, sequenceIds = []) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getAnonymizedData");
        span.setAttribute("anonymization.entity", entityName);
        span.setAttribute("anonymization.sequence_id_count", sequenceIds.length);
        try {
            let [entityService, serviceEntity] = entityName.split(".");
            const entity = cds?.services?.[entityService]?.entities?.[serviceEntity];
            if (!entity) {
                throw new AnonymizationError_1.AnonymizationError(`Entity "${entityName}" not found in CDS services. Ensure the entityName matches the format "<service_name>.<entity_name>".`, "ENTITY_NOT_FOUND", { entityName });
            }
            const sequenceColumn = Object.values(entity.elements).find((element) => typeof element["@anonymize"] === "string" &&
                element["@anonymize"].replace(/\s+/g, "").includes("is_sequence"));
            if (sequenceColumn === undefined) {
                throw new AnonymizationError_1.AnonymizationError(`Sequence column for entity "${entity.name}" not found!`, "SEQUENCE_COLUMN_NOT_FOUND", { entityName: entity.name });
            }
            const viewName = entityName.toUpperCase().replace(/\./g, "_") + "_ANOMYZ_V";
            // Validate the derived view name and column name as safe SQL identifiers
            (0, validation_utils_1.validateSqlIdentifier)(viewName, "viewName");
            const seqColName = sequenceColumn?.name?.toUpperCase();
            (0, validation_utils_1.validateSqlIdentifier)(seqColName, "sequenceColumnName");
            if (sequenceIds.length > 0) {
                // Validate sequenceIds are safe scalar values (strings or numbers only)
                for (let i = 0; i < sequenceIds.length; i++) {
                    const val = sequenceIds[i];
                    if (typeof val !== "string" && typeof val !== "number") {
                        throw new AnonymizationError_1.AnonymizationError(`Invalid sequenceId at index ${i}: must be a string or number. Received: ${typeof val}`, "INVALID_SEQUENCE_ID", { index: i, receivedType: typeof val });
                    }
                }
                // Use parameterized query with positional placeholders for sequenceIds
                const placeholders = sequenceIds.map(() => "?").join(", ");
                const query = `SELECT * FROM "${viewName}" WHERE "${seqColName}" IN (${placeholders})`;
                return await cds.db.run(query, sequenceIds);
            }
            const query = `SELECT * FROM "${viewName}"`;
            const result = await cds.db.run(query);
            span.addEvent("anonymized_data_fetched");
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            return result;
        }
        catch (e) {
            LOG.error(`Retrieving anonymized data from SAP HANA Cloud failed. Ensure that the entityName passed exactly matches the format "<service_name>.<entity_name>". Error: `, e);
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            throw e;
        }
        finally {
            span.end();
        }
    }
    /**
     * Get vector embeddings using environment-based Azure OpenAI configuration.
     *
     * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getEmbeddingWithConfig} instead.
     * @param {object} input - The input string to be embedded.
     * @returns {object} - Returns the vector embeddings.
     */
    async getEmbedding(input) {
        return legacy.getEmbedding(input);
    }
    /**
     * Generate vector embeddings using the SAP AI SDK OrchestrationEmbeddingClient.
     *
     * @param config - Embedding model configuration. Requires `modelName` and `resourceGroup`.
     * @param input - The text string (or array of strings) to embed.
     * @returns The SDK embedding response. Use `response.getEmbeddings()` to extract vectors.
     * @throws {Error} If `config.modelName` or `config.resourceGroup` is missing.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const config: EmbeddingConfig = { modelName: "text-embedding-ada-002", resourceGroup: "default", ... };
     * const response = await plugin.getEmbeddingWithConfig(config, "What is SAP HANA?");
     * const vector = response.getEmbeddings()[0].embedding;
     * ```
     */
    async getEmbeddingWithConfig(config, input) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getEmbeddingWithConfig");
        span.setAttribute("llm.embedding.model", config?.modelName ?? "");
        span.setAttribute("llm.resource_group", config?.resourceGroup ?? "");
        try {
            // Validate mandatory config params needed by the SDK
            if (!config?.modelName) {
                throw new EmbeddingError_1.EmbeddingError(`The config is missing the parameter: "modelName".`, "EMBEDDING_CONFIG_INVALID", {
                    missingField: "modelName",
                });
            }
            if (!config?.resourceGroup) {
                throw new EmbeddingError_1.EmbeddingError(`The config is missing the parameter: "resourceGroup".`, "EMBEDDING_CONFIG_INVALID", {
                    missingField: "resourceGroup",
                });
            }
            const { OrchestrationEmbeddingClient } = await Promise.resolve().then(() => __importStar(require("@sap-ai-sdk/orchestration")));
            const client = new OrchestrationEmbeddingClient({ embeddings: { model: { name: config.modelName } } }, { resourceGroup: config.resourceGroup });
            const response = await client.embed({ input: input }, {
                middleware: [
                    (0, ai_sdk_middleware_1.createOtelMiddleware)({
                        endpoint: "/embeddings",
                        resourceGroup: config.resourceGroup,
                    }),
                ],
            });
            span.addEvent("embedding_response_received");
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            return response;
        }
        catch (e) {
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            if (e instanceof EmbeddingError_1.EmbeddingError)
                throw e;
            throw new EmbeddingError_1.EmbeddingError(`Embedding request failed: ${e.message}`, "EMBEDDING_REQUEST_FAILED", {
                modelName: config.modelName,
                resourceGroup: config.resourceGroup,
                ...(config.deploymentUrl ? { deploymentUrl: config.deploymentUrl } : {}),
                cause: e.message,
            });
        }
        finally {
            span.end();
        }
    }
    /**
     * Perform chat completion using the SAP AI SDK OrchestrationClient.
     *
     * @param config - Chat model configuration. Requires `modelName` and `resourceGroup`.
     * @param payload - Chat payload with a `messages` array in OpenAI format.
     * @returns The SDK chat completion response.
     * @throws {Error} If `config.modelName` or `config.resourceGroup` is missing.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const config: ChatConfig = { modelName: "gpt-4o", resourceGroup: "default", ... };
     * const response = await plugin.getChatCompletionWithConfig(config, {
     *   messages: [{ role: "user", content: "Hello" }]
     * });
     * ```
     */
    async getChatCompletionWithConfig(config, payload) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getChatCompletionWithConfig");
        span.setAttribute("llm.chat.model", config?.modelName ?? "");
        span.setAttribute("llm.resource_group", config?.resourceGroup ?? "");
        try {
            // Validate mandatory config params needed by the SDK
            if (!config?.modelName) {
                throw new ChatCompletionError_1.ChatCompletionError(`The config is missing parameter: "modelName".`, "CHAT_CONFIG_INVALID", {
                    missingField: "modelName",
                });
            }
            if (!config?.resourceGroup) {
                throw new ChatCompletionError_1.ChatCompletionError(`The config is missing parameter: "resourceGroup".`, "CHAT_CONFIG_INVALID", {
                    missingField: "resourceGroup",
                });
            }
            const { OrchestrationClient } = await Promise.resolve().then(() => __importStar(require("@sap-ai-sdk/orchestration")));
            const client = new OrchestrationClient({
                promptTemplating: {
                    model: { name: config.modelName },
                },
            }, { resourceGroup: config.resourceGroup });
            const chatPayload = payload;
            const messages = chatPayload?.messages ?? []; // SDK expects ChatMessage[] — caller provides untyped payload
            const response = await client.chatCompletion({ messages }, {
                middleware: [
                    (0, ai_sdk_middleware_1.createOtelMiddleware)({
                        endpoint: "/chat/completions",
                        resourceGroup: config.resourceGroup,
                    }),
                ],
            });
            span.addEvent("chat_completion_response_received");
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            return response;
        }
        catch (e) {
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            if (e instanceof ChatCompletionError_1.ChatCompletionError)
                throw e;
            throw new ChatCompletionError_1.ChatCompletionError(`Chat completion request failed: ${e.message}`, "CHAT_COMPLETION_REQUEST_FAILED", {
                modelName: config.modelName,
                resourceGroup: config.resourceGroup,
                ...(config.deploymentUrl ? { deploymentUrl: config.deploymentUrl } : {}),
                cause: e.message,
            });
        }
        finally {
            span.end();
        }
    }
    /**
     * Perform chat completion using environment-based Azure OpenAI configuration.
     *
     * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getChatCompletionWithConfig} instead.
     * @param {object} payload - The payload for the chat completion model.
     * @returns {object} - The chat completion results from the model.
     */
    async getChatCompletion(payload) {
        return legacy.getChatCompletion(payload);
    }
    /**
     * Execute a full RAG (Retrieval-Augmented Generation) pipeline:
     * embed query → similarity search → chat completion.
     *
     * The pipeline:
     * 1. Embeds the user input via {@link getEmbeddingWithConfig}
     * 2. Searches HANA for similar documents via {@link similaritySearch}
     * 3. Constructs a system prompt with matched content
     * 4. Sends messages to the chat model via {@link getChatCompletionWithConfig}
     *
     * @param input - The user's query text.
     * @param tableName - HANA table containing vector embeddings.
     * @param embeddingColumnName - Column name containing embedding vectors.
     * @param contentColumn - Column name containing document text content.
     * @param chatInstruction - System prompt instruction. Similar content is injected in triple backticks.
     * @param embeddingConfig - Configuration for the embedding model.
     * @param chatConfig - Configuration for the chat completion model.
     * @param context - Optional conversation history (prior messages).
     * @param topK - Number of similarity search results to retrieve. Default `3`.
     * @param algoName - Similarity algorithm: `"COSINE_SIMILARITY"` (default) or `"L2DISTANCE"`.
     * @param chatParams - Optional additional chat parameters (unused with SDK, kept for backward compat).
     * @returns A {@link RagResponse} with `completion` and `additionalContents`.
     * @throws {Error} If embedding, similarity search, or chat completion fails.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const result = await plugin.getRagResponseWithConfig(
     *   "What is SAP HANA?",
     *   "DOCUMENTS", "EMBEDDING", "CONTENT",
     *   "Answer based on the following context.",
     *   embeddingConfig, chatConfig
     * );
     * console.log(result.completion);          // Chat response
     * console.log(result.additionalContents);  // Similar documents
     * ```
     */
    async getRagResponseWithConfig(input, tableName, embeddingColumnName, contentColumn, chatInstruction, embeddingConfig, chatConfig, context, topK = 3, algoName = "COSINE_SIMILARITY", chatParams) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getRagResponseWithConfig");
        span.setAttribute("llm.embedding.model", embeddingConfig.modelName ?? "");
        span.setAttribute("llm.chat.model", chatConfig.modelName ?? "");
        span.setAttribute("db.hana.table", tableName);
        span.setAttribute("db.hana.algo", algoName);
        span.setAttribute("llm.rag.top_k", topK);
        try {
            //get the embeddings for the user query via SDK
            const embeddingResponse = (await this.getEmbeddingWithConfig(embeddingConfig, input));
            const queryEmbedding = embeddingResponse.getEmbeddings()[0].embedding;
            span.addEvent("embedding_generated", { "embedding.dimensions": queryEmbedding.length });
            //perform similarity search on the vector db
            const similaritySearchResults = await this.similaritySearch(tableName, embeddingColumnName, contentColumn, queryEmbedding, algoName, topK);
            const similarContent = similaritySearchResults.map((obj) => obj.PAGE_CONTENT);
            span.addEvent("similarity_search_completed", {
                "search.result_count": similaritySearchResults.length,
            });
            //system prompt for the RagResponse.
            const systemPrompt = ` ${chatInstruction} \`\`\` ${similarContent} \`\`\` `;
            //construct a unified messages array — SDK handles model-specific formatting
            const messages = [{ role: "system", content: systemPrompt }];
            //push the memory context if passed
            if (context && context.length > 0) {
                LOG.debug("Using the context parameter passed.");
                messages.push(...context);
            }
            //push the user query
            messages.push({ role: "user", content: input });
            //retrieve the chat completion response via SDK
            const chatCompletionResp = await this.getChatCompletionWithConfig(chatConfig, { messages });
            span.addEvent("chat_completion_received");
            //construct the final response payload
            const ragResponse = {
                completion: chatCompletionResp, //complete response from chat completion model
                additionalContents: similaritySearchResults, //complete similarity search results
            };
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            return ragResponse;
        }
        catch (error) {
            // Handle any errors that occur during the execution
            LOG.error("Error while retrieving RAG response:", error);
            span.recordException(error);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: error.message });
            throw error;
        }
        finally {
            span.end();
        }
    }
    /**
     * Retrieve RAG response using environment-based Azure OpenAI configuration.
     *
     * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getRagResponseWithConfig} instead.
     * @param {string} input - User input.
     * @param {string} tableName - The HANA Cloud table with vector embeddings.
     * @param {string} embeddingColumnName - The column with embeddings.
     * @param {string} contentColumn - The column with page content.
     * @param {string} chatInstruction - The system prompt instruction.
     * @param {object} context - Optional chat history.
     * @param {number} topK - Number of entries to return. Default 3.
     * @param {string} algoName - Similarity algorithm. Default 'COSINE_SIMILARITY'.
     * @param {object} chatParams - Optional additional chat params.
     * @returns {object} Returns the response from LLM.
     */
    async getRagResponse(input, tableName, embeddingColumnName, contentColumn, chatInstruction, context, topK = 3, algoName = "COSINE_SIMILARITY", chatParams) {
        return legacy.getRagResponse(this.getEmbedding.bind(this), this.similaritySearch.bind(this), this.getChatCompletion.bind(this), input, tableName, embeddingColumnName, contentColumn, chatInstruction, context, topK, algoName, chatParams);
    }
    /**
     * Perform vector similarity search against SAP HANA Cloud.
     *
     * Constructs and executes a SQL query using the specified algorithm
     * to find the most similar documents to the given embedding vector.
     *
     * @param tableName - HANA table containing vector embeddings.
     * @param embeddingColumnName - Column containing embedding vectors.
     * @param contentColumn - Column containing document text content.
     * @param embedding - The query embedding vector (numeric array).
     * @param algoName - `"COSINE_SIMILARITY"` or `"L2DISTANCE"`.
     * @param topK - Number of results to return (max 10000).
     * @returns Array of {@link SimilaritySearchResult} with `PAGE_CONTENT` and `SCORE`, or `undefined`.
     * @throws {InvalidSimilaritySearchAlgoNameError} If algorithm name is invalid.
     * @throws {Error} If SQL identifiers or embedding vector fail validation.
     */
    async similaritySearch(tableName, embeddingColumnName, contentColumn, embedding, algoName, topK) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.similaritySearch");
        span.setAttribute("db.hana.table", tableName);
        span.setAttribute("db.hana.algo", algoName);
        span.setAttribute("db.hana.top_k", topK);
        span.setAttribute("db.hana.embedding_dims", embedding?.length ?? 0);
        try {
            // Validate all inputs before constructing SQL
            (0, validation_utils_1.validateSqlIdentifier)(tableName, "tableName");
            (0, validation_utils_1.validateSqlIdentifier)(embeddingColumnName, "embeddingColumnName");
            (0, validation_utils_1.validateSqlIdentifier)(contentColumn, "contentColumn");
            (0, validation_utils_1.validatePositiveInteger)(topK, "topK", 10000);
            (0, validation_utils_1.validateEmbeddingVector)(embedding);
            // Ensure algoName is valid
            const validAlgorithms = ["COSINE_SIMILARITY", "L2DISTANCE"];
            if (!validAlgorithms.includes(algoName)) {
                throw new InvalidSimilaritySearchAlgoNameError(`Invalid algorithm name: ${algoName}. Currently only COSINE_SIMILARITY and L2DISTANCE are accepted.`, 400);
            }
            // Prefer @sap-ai-sdk/hana-vector HANAVectorStore when available
            let sdkResult;
            try {
                const { createHANAClientFromEnv, createHANAVectorStore } = await Promise.resolve(`${"@sap-ai-sdk/hana-vector"}`).then(s => __importStar(require(s)));
                const hanaClient = createHANAClientFromEnv();
                await hanaClient.init();
                const metricMap = {
                    COSINE_SIMILARITY: "COSINE",
                    L2DISTANCE: "EUCLIDEAN",
                };
                const vectorStore = createHANAVectorStore(hanaClient, {
                    tableName,
                    embeddingColumn: embeddingColumnName,
                    contentColumn,
                    embeddingDimensions: embedding.length,
                });
                const hits = await vectorStore.similaritySearch(embedding, {
                    k: topK,
                    metric: metricMap[algoName] ?? "COSINE",
                });
                sdkResult = hits.map((h) => ({
                    PAGE_CONTENT: h.content ?? h.metadata?.content ?? "",
                    SCORE: h.score ?? 0,
                    ...h,
                }));
                await hanaClient.disconnect?.();
            }
            catch (sdkErr) {
                LOG.debug("@sap-ai-sdk/hana-vector not available, falling back to raw SQL:", sdkErr.message);
                sdkResult = undefined;
            }
            if (sdkResult !== undefined) {
                span.addEvent("similarity_search_completed", {
                    "search.result_count": sdkResult.length,
                    "search.method": "hana-vector-sdk",
                });
                span.setStatus({ code: tracer_1.SpanStatusCode.OK });
                return sdkResult;
            }
            // Raw SQL fallback (original implementation)
            let sortDirection = "DESC";
            if ("L2DISTANCE" === algoName) {
                sortDirection = "ASC";
            }
            // Safely construct the embedding string from validated numeric array
            const embeddingStr = "'[" + embedding.join(",") + "]'";
            // Use double-quoted identifiers for all table/column names to prevent injection
            const selectStmt = `SELECT TOP ${Number(topK)} *,TO_NVARCHAR("${contentColumn}") as PAGE_CONTENT,${algoName}("${embeddingColumnName}", TO_REAL_VECTOR(${embeddingStr})) as SCORE FROM "${tableName}" ORDER BY SCORE ${sortDirection}`;
            const db = (await cds.connect.to("db"));
            const result = await db.run(selectStmt);
            if (result) {
                span.addEvent("similarity_search_completed", {
                    "search.result_count": result.length,
                    "search.method": "raw-sql",
                });
                span.setStatus({ code: tracer_1.SpanStatusCode.OK });
                return result;
            }
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
        }
        catch (e) {
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            if (e instanceof InvalidSimilaritySearchAlgoNameError) {
                throw e;
            }
            else {
                LOG.error(`Similarity Search failed for entity ${tableName} on attribute ${embeddingColumnName}`, e);
                throw e;
            }
        }
        finally {
            span.end();
        }
    }
    /**
     * Chat completion via the SAP AI SDK OrchestrationClient with optional response extraction.
     *
     * Supports the full Orchestration Service feature set including prompt templating,
     * input/output filtering, and grounding. Use the boolean flags to extract specific
     * parts of the response (only the first truthy flag takes effect).
     *
     * @param params - {@link HarmonizedChatCompletionParams} with `clientConfig`, `chatCompletionConfig`, and optional flags.
     * @param params.clientConfig - OrchestrationClient configuration (model, templating, filtering, etc.).
     * @param params.chatCompletionConfig - Chat completion request (messages, inputParams, etc.).
     * @param params.getContent - If `true`, returns only the message content string.
     * @param params.getTokenUsage - If `true`, returns only the token usage object.
     * @param params.getFinishReason - If `true`, returns only the finish reason string.
     * @returns The full response, or extracted content/tokenUsage/finishReason based on flags.
     * @throws {Error} If the OrchestrationClient or chat completion request fails.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const content = await plugin.getHarmonizedChatCompletion({
     *   clientConfig: { promptTemplating: { model: { name: "gpt-4o" } } },
     *   chatCompletionConfig: { messages: [{ role: "user", content: "Hello" }] },
     *   getContent: true,
     * });
     * ```
     */
    async getHarmonizedChatCompletion({ clientConfig, chatCompletionConfig, getContent = false, getTokenUsage = false, getFinishReason = false, }) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getHarmonizedChatCompletion");
        span.setAttribute("llm.harmonized.get_content", getContent);
        span.setAttribute("llm.harmonized.get_token_usage", getTokenUsage);
        span.setAttribute("llm.harmonized.get_finish_reason", getFinishReason);
        try {
            const { OrchestrationClient } = await Promise.resolve().then(() => __importStar(require("@sap-ai-sdk/orchestration")));
            // Initialize the OrchestrationClient with the provided client configuration
            const orchestrationClient = new OrchestrationClient(clientConfig);
            // Call the chatCompletion method with the provided chat completion configuration
            const response = await orchestrationClient.chatCompletion(chatCompletionConfig);
            span.addEvent("harmonized_chat_completion_received");
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            // Extract the desired content from the response based on the flags
            switch (true) {
                case getContent:
                    return response.getContent();
                case getTokenUsage:
                    return response.getTokenUsage();
                case getFinishReason:
                    return response.getFinishReason();
                default:
                    return response;
            }
        }
        catch (e) {
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            if (e instanceof ChatCompletionError_1.ChatCompletionError)
                throw e;
            throw new ChatCompletionError_1.ChatCompletionError(`Harmonized chat completion failed: ${e.message}`, "HARMONIZED_CHAT_FAILED", { cause: e.message });
        }
        finally {
            span.end();
        }
    }
    /**
     * Stream chat completion tokens as Server-Sent Events (SSE).
     *
     * When called via HTTP (e.g. from an Angular front-end), writes SSE frames
     * directly to `req.http.res` and returns an empty string. When called
     * programmatically without an HTTP response (e.g. unit tests), returns the
     * fully accumulated content string instead.
     *
     * SSE frame format:
     *   delta frame  — `data: {"delta":"<token>","index":0}\n\n`
     *   done frame   — `data: {"finishReason":"stop","totalTokens":42}\n\n`
     *   sentinel     — `data: [DONE]\n\n`
     *   error frame  — `event: error\ndata: {"code":"...","message":"..."}\n\n`
     *
     * Client disconnect is detected via the `close` event on the HTTP response,
     * which aborts the upstream AI Core stream via `AbortController`.
     *
     * @param params - {@link StreamChatParams} with `clientConfig` and `chatCompletionConfig`.
     * @param req - Optional CDS request (provides `req.http.res` for SSE output).
     * @returns Empty string (SSE mode) or full accumulated content (non-SSE mode).
     * @throws {ChatCompletionError} If streaming fails and SSE is not active.
     */
    async streamChatCompletion(params, req) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.streamChatCompletion");
        const httpRes = req?.http?.res;
        const isStreaming = !!(httpRes && !httpRes.headersSent);
        if (isStreaming) {
            httpRes.setHeader("Content-Type", "text/event-stream");
            httpRes.setHeader("Cache-Control", "no-cache");
            httpRes.setHeader("X-Accel-Buffering", "no");
            httpRes.setHeader("Connection", "keep-alive");
            httpRes.flushHeaders();
        }
        const controller = new AbortController();
        if (isStreaming) {
            httpRes.on("close", () => { controller.abort(); });
        }
        let clientConfig;
        let chatCompletionConfig;
        try {
            clientConfig = JSON.parse(params.clientConfig);
            chatCompletionConfig = JSON.parse(params.chatCompletionConfig);
        }
        catch (parseErr) {
            const err = new ChatCompletionError_1.ChatCompletionError(`streamChatCompletion: invalid JSON in params — ${parseErr.message}`, "STREAM_CHAT_PARAMS_INVALID", { cause: parseErr.message });
            span.recordException(err);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: err.message });
            span.end();
            throw err;
        }
        try {
            const { OrchestrationClient } = await Promise.resolve().then(() => __importStar(require("@sap-ai-sdk/orchestration")));
            const client = new OrchestrationClient(clientConfig);
            const streamResponse = await client.stream(chatCompletionConfig, controller.signal, undefined, {
                middleware: [
                    (0, ai_sdk_middleware_1.createOtelMiddleware)({ endpoint: "/chat/completions" }),
                ],
            });
            span.addEvent("stream_started");
            let fullContent = "";
            for await (const chunk of streamResponse.stream) {
                const delta = chunk.getDeltaContent();
                if (!delta)
                    continue;
                fullContent += delta;
                if (isStreaming) {
                    const frame = JSON.stringify({ delta, index: 0 });
                    httpRes.write(`data: ${frame}\n\n`);
                }
            }
            const finishReason = streamResponse.getFinishReason();
            const totalTokens = streamResponse.getTokenUsage()?.total_tokens;
            span.addEvent("stream_completed", {
                ...(finishReason ? { "stream.finish_reason": finishReason } : {}),
                ...(totalTokens !== undefined ? { "stream.total_tokens": totalTokens } : {}),
            });
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            if (isStreaming) {
                const doneFrame = JSON.stringify({ finishReason, totalTokens });
                httpRes.write(`data: ${doneFrame}\n\n`);
                httpRes.write("data: [DONE]\n\n");
                httpRes.end();
                return "";
            }
            return fullContent;
        }
        catch (e) {
            const err = e;
            span.recordException(err);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: err.message });
            if (isStreaming) {
                const errFrame = JSON.stringify({ code: "CHAT_STREAM_FAILED", message: err.message });
                try {
                    httpRes.write(`event: error\ndata: ${errFrame}\n\n`);
                    httpRes.end();
                }
                catch {
                    // socket already closed — ignore write errors
                }
                return "";
            }
            if (e instanceof ChatCompletionError_1.ChatCompletionError)
                throw e;
            throw new ChatCompletionError_1.ChatCompletionError(`streamChatCompletion failed: ${err.message}`, "CHAT_STREAM_FAILED", { cause: err.message });
        }
        finally {
            span.end();
        }
    }
    /**
     * Build a content safety filter for use with the Orchestration Service.
     *
     * Currently supports Azure Content Safety filters only. The returned filter
     * object can be passed to `getHarmonizedChatCompletion` via `clientConfig.inputFiltering`.
     *
     * @param params - {@link ContentFilterParams} with `type` and `config`.
     * @param params.type - Filter provider type. Currently only `"azure"` is supported (case-insensitive).
     * @param params.config - Provider-specific filter configuration (e.g., `{ Hate: 2, Violence: 4 }`).
     * @returns The constructed filter object from the SDK.
     * @throws {Error} If the type is not `"azure"`.
     *
     * @example
     * ```typescript
     * const plugin = await cds.connect.to("cap-llm-plugin");
     * const filter = await plugin.getContentFilters({ type: "azure", config: { Hate: 2, Violence: 4 } });
     * ```
     */
    async getContentFilters({ type, config }) {
        const span = (0, tracer_1.getTracer)().startSpan("cap-llm-plugin.getContentFilters");
        span.setAttribute("content_filter.type", type);
        // If the 'type' is not 'azure', throw an error with a helpful message
        if (type.toLowerCase() !== "azure") {
            const err = new ChatCompletionError_1.ChatCompletionError(`Unsupported type ${type}. The currently supported type is 'azure'.`, "UNSUPPORTED_FILTER_TYPE", { type, supportedTypes: ["azure"] });
            span.recordException(err);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: err.message });
            span.end();
            throw err;
        }
        try {
            const { buildAzureContentSafetyFilter } = await Promise.resolve().then(() => __importStar(require("@sap-ai-sdk/orchestration")));
            const result = buildAzureContentSafetyFilter(config);
            span.addEvent("content_filter_built");
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
            return result;
        }
        catch (e) {
            span.recordException(e);
            span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: e.message });
            if (e instanceof ChatCompletionError_1.ChatCompletionError)
                throw e;
            throw new ChatCompletionError_1.ChatCompletionError(`Content filter construction failed: ${e.message}`, "CONTENT_FILTER_FAILED", { type, cause: e.message });
        }
        finally {
            span.end();
        }
    }
}
module.exports = CAPLLMPlugin;
//# sourceMappingURL=cap-llm-plugin.js.map