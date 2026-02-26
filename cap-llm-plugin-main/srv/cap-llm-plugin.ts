import * as cds from "@sap/cds";
import InvalidSimilaritySearchAlgoNameError = require("./errors/InvalidSimilaritySearchAlgoNameError");
import { validateSqlIdentifier, validatePositiveInteger, validateEmbeddingVector } from "../lib/validation-utils";
import * as legacy from "./legacy";
import { AnonymizationError } from "../src/errors/AnonymizationError";
import { EmbeddingError } from "../src/errors/EmbeddingError";
import { ChatCompletionError } from "../src/errors/ChatCompletionError";
import { getTracer, SpanStatusCode } from "../src/telemetry/tracer";
import { createOtelMiddleware } from "../src/telemetry/ai-sdk-middleware";

const LOG = (cds as any).log("cap-llm-plugin") as {
  debug: (...args: unknown[]) => void;
  info: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
};

// ════════════════════════════════════════════════════════════════════
// Public interfaces
// ════════════════════════════════════════════════════════════════════

/** Configuration for an embedding model destination. */
export interface EmbeddingConfig {
  destinationName: string;
  resourceGroup: string;
  deploymentUrl: string;
  modelName: string;
  apiVersion?: string;
}

/** Configuration for a chat completion model destination. */
export interface ChatConfig {
  destinationName: string;
  resourceGroup: string;
  deploymentUrl: string;
  modelName: string;
  apiVersion?: string;
}

/** A single chat message in OpenAI/Claude format. */
export interface ChatMessage {
  role: string;
  content: string;
}

/** A Gemini-format message with parts. */
export interface GeminiMessage {
  role: string;
  parts: { text: string }[];
}

/** GPT chat completion payload. */
export interface GptChatPayload {
  messages: Record<string, unknown>[];
  [key: string]: unknown;
}

/** Gemini chat completion payload. */
export interface GeminiChatPayload {
  contents: Record<string, unknown>[];
  generationConfig?: Record<string, unknown>;
  [key: string]: unknown;
}

/** Claude chat completion payload. */
export interface ClaudeChatPayload {
  messages: Record<string, unknown>[];
  system: string;
  [key: string]: unknown;
}

/** Union of all supported chat payload formats. */
export type ChatPayload = GptChatPayload | GeminiChatPayload | ClaudeChatPayload;

/** Result from similarity search. */
export interface SimilaritySearchResult {
  PAGE_CONTENT: string;
  SCORE: number;
  [key: string]: unknown;
}

/** Response from the RAG pipeline. */
export interface RagResponse {
  completion: unknown;
  additionalContents: SimilaritySearchResult[];
}

/** Flags for getHarmonizedChatCompletion. */
export interface HarmonizedChatCompletionParams {
  clientConfig: unknown;
  chatCompletionConfig: unknown;
  getContent?: boolean;
  getTokenUsage?: boolean;
  getFinishReason?: boolean;
}

/** Params for getContentFilters. */
export interface ContentFilterParams {
  type: string;
  config: unknown;
}

// ════════════════════════════════════════════════════════════════════

class CAPLLMPlugin extends cds.Service {
  async init(): Promise<void> {
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
  async getAnonymizedData(entityName: string, sequenceIds: (string | number)[] = []): Promise<unknown> {
    const span = getTracer().startSpan("cap-llm-plugin.getAnonymizedData");
    span.setAttribute("anonymization.entity", entityName);
    span.setAttribute("anonymization.sequence_id_count", sequenceIds.length);

    try {
      let [entityService, serviceEntity] = entityName.split(".");
      const entity = (cds as any)?.services?.[entityService]?.entities?.[serviceEntity];

      if (!entity) {
        throw new AnonymizationError(
          `Entity "${entityName}" not found in CDS services. Ensure the entityName matches the format "<service_name>.<entity_name>".`,
          "ENTITY_NOT_FOUND",
          { entityName }
        );
      }

      const sequenceColumn = Object.values(entity.elements as Record<string, Record<string, unknown>>).find(
        (element: Record<string, unknown>) =>
          typeof element["@anonymize"] === "string" &&
          (element["@anonymize"] as string).replace(/\s+/g, "").includes("is_sequence")
      ) as Record<string, unknown> | undefined;
      if (sequenceColumn === undefined) {
        throw new AnonymizationError(
          `Sequence column for entity "${entity.name}" not found!`,
          "SEQUENCE_COLUMN_NOT_FOUND",
          { entityName: entity.name }
        );
      }
      const viewName = entityName.toUpperCase().replace(/\./g, "_") + "_ANOMYZ_V";

      // Validate the derived view name and column name as safe SQL identifiers
      validateSqlIdentifier(viewName, "viewName");
      const seqColName = (sequenceColumn?.name as string)?.toUpperCase();
      validateSqlIdentifier(seqColName, "sequenceColumnName");

      if (sequenceIds.length > 0) {
        // Validate sequenceIds are safe scalar values (strings or numbers only)
        for (let i = 0; i < sequenceIds.length; i++) {
          const val = sequenceIds[i];
          if (typeof val !== "string" && typeof val !== "number") {
            throw new AnonymizationError(
              `Invalid sequenceId at index ${i}: must be a string or number. Received: ${typeof val}`,
              "INVALID_SEQUENCE_ID",
              { index: i, receivedType: typeof val }
            );
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
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (e) {
      LOG.error(
        `Retrieving anonymized data from SAP HANA Cloud failed. Ensure that the entityName passed exactly matches the format "<service_name>.<entity_name>". Error: `,
        e
      );
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      throw e;
    } finally {
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
  async getEmbedding(input: unknown): Promise<number[]> {
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
  async getEmbeddingWithConfig(config: EmbeddingConfig, input: unknown): Promise<unknown> {
    const span = getTracer().startSpan("cap-llm-plugin.getEmbeddingWithConfig");
    span.setAttribute("llm.embedding.model", config?.modelName ?? "");
    span.setAttribute("llm.resource_group", config?.resourceGroup ?? "");

    try {
      // Validate mandatory config params needed by the SDK
      if (!config?.modelName) {
        throw new EmbeddingError(`The config is missing the parameter: "modelName".`, "EMBEDDING_CONFIG_INVALID", {
          missingField: "modelName",
        });
      }
      if (!config?.resourceGroup) {
        throw new EmbeddingError(`The config is missing the parameter: "resourceGroup".`, "EMBEDDING_CONFIG_INVALID", {
          missingField: "resourceGroup",
        });
      }

      const { OrchestrationEmbeddingClient } = await import("@sap-ai-sdk/orchestration");

      const client = new OrchestrationEmbeddingClient(
        { embeddings: { model: { name: config.modelName as any } } },
        { resourceGroup: config.resourceGroup }
      );

      const response = await client.embed(
        { input: input as string | string[] },
        {
          middleware: [
            createOtelMiddleware({
              endpoint: "/embeddings",
              resourceGroup: config.resourceGroup,
            }),
          ],
        }
      );
      span.addEvent("embedding_response_received");
      span.setStatus({ code: SpanStatusCode.OK });
      return response;
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      if (e instanceof EmbeddingError) throw e;
      throw new EmbeddingError(`Embedding request failed: ${(e as Error).message}`, "EMBEDDING_REQUEST_FAILED", {
        modelName: config.modelName,
        resourceGroup: config.resourceGroup,
        ...(config.deploymentUrl ? { deploymentUrl: config.deploymentUrl } : {}),
        cause: (e as Error).message,
      });
    } finally {
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
  async getChatCompletionWithConfig(config: ChatConfig, payload: unknown): Promise<unknown> {
    const span = getTracer().startSpan("cap-llm-plugin.getChatCompletionWithConfig");
    span.setAttribute("llm.chat.model", config?.modelName ?? "");
    span.setAttribute("llm.resource_group", config?.resourceGroup ?? "");

    try {
      // Validate mandatory config params needed by the SDK
      if (!config?.modelName) {
        throw new ChatCompletionError(`The config is missing parameter: "modelName".`, "CHAT_CONFIG_INVALID", {
          missingField: "modelName",
        });
      }
      if (!config?.resourceGroup) {
        throw new ChatCompletionError(`The config is missing parameter: "resourceGroup".`, "CHAT_CONFIG_INVALID", {
          missingField: "resourceGroup",
        });
      }

      const { OrchestrationClient } = await import("@sap-ai-sdk/orchestration");

      const client = new OrchestrationClient(
        {
          promptTemplating: {
            model: { name: config.modelName as any },
          },
        },
        { resourceGroup: config.resourceGroup }
      );

      const chatPayload = payload as Record<string, unknown>;
      const messages = (chatPayload?.messages as any[]) ?? []; // SDK expects ChatMessage[] — caller provides untyped payload

      const response = await client.chatCompletion(
        { messages },
        {
          middleware: [
            createOtelMiddleware({
              endpoint: "/chat/completions",
              resourceGroup: config.resourceGroup,
            }),
          ],
        }
      );
      span.addEvent("chat_completion_response_received");
      span.setStatus({ code: SpanStatusCode.OK });
      return response;
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      if (e instanceof ChatCompletionError) throw e;
      throw new ChatCompletionError(
        `Chat completion request failed: ${(e as Error).message}`,
        "CHAT_COMPLETION_REQUEST_FAILED",
        {
          modelName: config.modelName,
          resourceGroup: config.resourceGroup,
          ...(config.deploymentUrl ? { deploymentUrl: config.deploymentUrl } : {}),
          cause: (e as Error).message,
        }
      );
    } finally {
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
  async getChatCompletion(payload: unknown): Promise<unknown> {
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
  async getRagResponseWithConfig(
    input: string,
    tableName: string,
    embeddingColumnName: string,
    contentColumn: string,
    chatInstruction: string,
    embeddingConfig: EmbeddingConfig,
    chatConfig: ChatConfig,
    context: unknown[] | undefined,
    topK: number = 3,
    algoName: string = "COSINE_SIMILARITY",
    chatParams?: Record<string, unknown>
  ): Promise<RagResponse> {
    const span = getTracer().startSpan("cap-llm-plugin.getRagResponseWithConfig");
    span.setAttribute("llm.embedding.model", embeddingConfig.modelName ?? "");
    span.setAttribute("llm.chat.model", chatConfig.modelName ?? "");
    span.setAttribute("db.hana.table", tableName);
    span.setAttribute("db.hana.algo", algoName);
    span.setAttribute("llm.rag.top_k", topK);

    try {
      //get the embeddings for the user query via SDK
      const embeddingResponse = (await this.getEmbeddingWithConfig(embeddingConfig, input)) as {
        getEmbeddings: () => Array<{ embedding: number[] }>;
      };
      const queryEmbedding: number[] = embeddingResponse.getEmbeddings()[0].embedding;

      span.addEvent("embedding_generated", { "embedding.dimensions": queryEmbedding.length });

      //perform similarity search on the vector db
      const similaritySearchResults = await this.similaritySearch(
        tableName,
        embeddingColumnName,
        contentColumn,
        queryEmbedding!,
        algoName,
        topK
      );
      const similarContent = (similaritySearchResults as SimilaritySearchResult[]).map(
        (obj: SimilaritySearchResult) => obj.PAGE_CONTENT
      );

      span.addEvent("similarity_search_completed", {
        "search.result_count": (similaritySearchResults as SimilaritySearchResult[]).length,
      });

      //system prompt for the RagResponse.
      const systemPrompt = ` ${chatInstruction} \`\`\` ${similarContent} \`\`\` `;

      //construct a unified messages array — SDK handles model-specific formatting
      const messages: Record<string, unknown>[] = [{ role: "system", content: systemPrompt }];

      //push the memory context if passed
      if (context && context.length > 0) {
        LOG.debug("Using the context parameter passed.");
        messages.push(...(context as Record<string, unknown>[]));
      }

      //push the user query
      messages.push({ role: "user", content: input });

      //retrieve the chat completion response via SDK
      const chatCompletionResp = await this.getChatCompletionWithConfig(chatConfig, { messages });

      span.addEvent("chat_completion_received");

      //construct the final response payload
      const ragResponse: RagResponse = {
        completion: chatCompletionResp, //complete response from chat completion model
        additionalContents: similaritySearchResults as SimilaritySearchResult[], //complete similarity search results
      };

      span.setStatus({ code: SpanStatusCode.OK });
      return ragResponse;
    } catch (error) {
      // Handle any errors that occur during the execution
      LOG.error("Error while retrieving RAG response:", error);
      span.recordException(error as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (error as Error).message });
      throw error;
    } finally {
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
  async getRagResponse(
    input: string,
    tableName: string,
    embeddingColumnName: string,
    contentColumn: string,
    chatInstruction: string,
    context: unknown[] | undefined,
    topK: number = 3,
    algoName: string = "COSINE_SIMILARITY",
    chatParams?: Record<string, unknown>
  ): Promise<{ completion: unknown; additionalContents: unknown[] }> {
    return legacy.getRagResponse(
      this.getEmbedding.bind(this) as any,
      this.similaritySearch.bind(this) as any,
      this.getChatCompletion.bind(this) as any,
      input,
      tableName,
      embeddingColumnName,
      contentColumn,
      chatInstruction,
      context,
      topK,
      algoName,
      chatParams
    );
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
  async similaritySearch(
    tableName: string,
    embeddingColumnName: string,
    contentColumn: string,
    embedding: number[],
    algoName: string,
    topK: number
  ): Promise<SimilaritySearchResult[] | undefined> {
    const span = getTracer().startSpan("cap-llm-plugin.similaritySearch");
    span.setAttribute("db.hana.table", tableName);
    span.setAttribute("db.hana.algo", algoName);
    span.setAttribute("db.hana.top_k", topK);
    span.setAttribute("db.hana.embedding_dims", embedding?.length ?? 0);

    try {
      // Validate all inputs before constructing SQL
      validateSqlIdentifier(tableName, "tableName");
      validateSqlIdentifier(embeddingColumnName, "embeddingColumnName");
      validateSqlIdentifier(contentColumn, "contentColumn");
      validatePositiveInteger(topK, "topK", 10000);
      validateEmbeddingVector(embedding);

      // Ensure algoName is valid
      const validAlgorithms = ["COSINE_SIMILARITY", "L2DISTANCE"];
      if (!validAlgorithms.includes(algoName)) {
        throw new InvalidSimilaritySearchAlgoNameError(
          `Invalid algorithm name: ${algoName}. Currently only COSINE_SIMILARITY and L2DISTANCE are accepted.`,
          400
        );
      }
      let sortDirection = "DESC";
      if ("L2DISTANCE" === algoName) {
        sortDirection = "ASC";
      }

      // Safely construct the embedding string from validated numeric array
      const embeddingStr = "'[" + embedding.join(",") + "]'";

      // Use double-quoted identifiers for all table/column names to prevent injection
      const selectStmt = `SELECT TOP ${Number(topK)} *,TO_NVARCHAR("${contentColumn}") as PAGE_CONTENT,${algoName}("${embeddingColumnName}", TO_REAL_VECTOR(${embeddingStr})) as SCORE FROM "${tableName}" ORDER BY SCORE ${sortDirection}`;
      const db = (await cds.connect.to("db")) as any;
      const result = await db.run(selectStmt);
      if (result) {
        span.addEvent("similarity_search_completed", { "search.result_count": result.length });
        span.setStatus({ code: SpanStatusCode.OK });
        return result;
      }
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      if (e instanceof InvalidSimilaritySearchAlgoNameError) {
        throw e;
      } else {
        LOG.error(`Similarity Search failed for entity ${tableName} on attribute ${embeddingColumnName}`, e);
        throw e;
      }
    } finally {
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
  async getHarmonizedChatCompletion({
    clientConfig,
    chatCompletionConfig,
    getContent = false,
    getTokenUsage = false,
    getFinishReason = false,
  }: HarmonizedChatCompletionParams): Promise<unknown> {
    const span = getTracer().startSpan("cap-llm-plugin.getHarmonizedChatCompletion");
    span.setAttribute("llm.harmonized.get_content", getContent);
    span.setAttribute("llm.harmonized.get_token_usage", getTokenUsage);
    span.setAttribute("llm.harmonized.get_finish_reason", getFinishReason);

    try {
      const { OrchestrationClient } = await import("@sap-ai-sdk/orchestration");

      // Initialize the OrchestrationClient with the provided client configuration
      const orchestrationClient = new OrchestrationClient(clientConfig as any);

      // Call the chatCompletion method with the provided chat completion configuration
      const response = await orchestrationClient.chatCompletion(chatCompletionConfig as any);

      span.addEvent("harmonized_chat_completion_received");
      span.setStatus({ code: SpanStatusCode.OK });

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
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      if (e instanceof ChatCompletionError) throw e;
      throw new ChatCompletionError(
        `Harmonized chat completion failed: ${(e as Error).message}`,
        "HARMONIZED_CHAT_FAILED",
        { cause: (e as Error).message }
      );
    } finally {
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

  async getContentFilters({ type, config }: ContentFilterParams): Promise<unknown> {
    const span = getTracer().startSpan("cap-llm-plugin.getContentFilters");
    span.setAttribute("content_filter.type", type);

    // If the 'type' is not 'azure', throw an error with a helpful message
    if (type.toLowerCase() !== "azure") {
      const err = new ChatCompletionError(
        `Unsupported type ${type}. The currently supported type is 'azure'.`,
        "UNSUPPORTED_FILTER_TYPE",
        { type, supportedTypes: ["azure"] }
      );
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.end();
      throw err;
    }

    try {
      const { buildAzureContentSafetyFilter } = await import("@sap-ai-sdk/orchestration");
      const result = buildAzureContentSafetyFilter(config as any);
      span.addEvent("content_filter_built");
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (e) {
      span.recordException(e as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (e as Error).message });
      if (e instanceof ChatCompletionError) throw e;
      throw new ChatCompletionError(
        `Content filter construction failed: ${(e as Error).message}`,
        "CONTENT_FILTER_FAILED",
        { type, cause: (e as Error).message }
      );
    } finally {
      span.end();
    }
  }
}

module.exports = CAPLLMPlugin;
