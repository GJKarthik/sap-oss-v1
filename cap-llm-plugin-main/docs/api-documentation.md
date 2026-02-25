## CAP LLM Plugin — API Documentation

> **TypeScript-first.** All methods are fully typed. Import types from `cap-llm-plugin`:
>
> ```typescript
> import type { EmbeddingConfig, ChatConfig, RagResponse } from "cap-llm-plugin";
> ```

---

### Configuration

The plugin uses the `@sap-ai-sdk/orchestration` SDK for all AI model interactions.
You need `modelName` and `resourceGroup` in your config objects. The SDK handles
model routing, API versioning, and destination connectivity automatically.

```json
{
  "cds": {
    "requires": {
      "gen-ai-hub": {
        "embedding": {
          "modelName": "text-embedding-ada-002",
          "resourceGroup": "default"
        },
        "chat": {
          "modelName": "gpt-4o",
          "resourceGroup": "default"
        }
      }
    }
  }
}
```

Refer to the [SAP AI Core documentation](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/models-and-scenarios-in-generative-ai-hub) for supported models.

---

### Prerequisites (Orchestration Service)

Before using `getHarmonizedChatCompletion` or `getContentFilters`, ensure you meet the
[@sap-ai-sdk/orchestration prerequisites](https://www.npmjs.com/package/@sap-ai-sdk/orchestration#prerequisites).

Bind the SAP AI Core service instance to your CAP application:

- **Hybrid testing:**

  ```bash
  cf create-service-key <ai-core-instance> <key-name>
  cds bind -2 <ai-core-instance>:<key-name>
  ```

- **BTP deployment:** Add the AI Core service instance to `mta.yaml` resources and require it in the srv module.

---

## Core Methods

### `getAnonymizedData(entityName, sequenceIds?)`

Retrieve anonymized data from a HANA anonymized view.

| Parameter     | Type                   | Description                                     |
| ------------- | ---------------------- | ----------------------------------------------- |
| `entityName`  | `string`               | Fully qualified: `"ServiceName.EntityName"`     |
| `sequenceIds` | `(string \| number)[]` | Optional. Filter by sequence IDs. Default `[]`. |

**Returns:** Anonymized rows from the HANA view.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");
const data = await plugin.getAnonymizedData("EmployeeService.Employees", [1001, 1002]);
```

Refer to the [anonymization usage doc](./anonymization-usage.md) for more details.

---

### `getEmbeddingWithConfig(config, input)`

Generate vector embeddings via the SAP AI SDK `OrchestrationEmbeddingClient`.

| Parameter | Type                 | Description                               |
| --------- | -------------------- | ----------------------------------------- |
| `config`  | `EmbeddingConfig`    | Requires `modelName` and `resourceGroup`. |
| `input`   | `string \| string[]` | Text to embed.                            |

**Returns:** SDK embedding response. Use `.getEmbeddings()` to extract vectors.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");
const embeddingConfig: EmbeddingConfig = cds.env.requires["gen-ai-hub"]["embedding"];

const response = await plugin.getEmbeddingWithConfig(embeddingConfig, "What is SAP HANA?");
const vector = response.getEmbeddings()[0].embedding;
```

---

### `getChatCompletionWithConfig(config, payload)`

Perform chat completion via the SAP AI SDK `OrchestrationClient`.

| Parameter | Type                  | Description                               |
| --------- | --------------------- | ----------------------------------------- |
| `config`  | `ChatConfig`          | Requires `modelName` and `resourceGroup`. |
| `payload` | `{ messages: Array }` | Chat messages in OpenAI format.           |

**Returns:** SDK chat completion response.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");
const chatConfig: ChatConfig = cds.env.requires["gen-ai-hub"]["chat"];

const response = await plugin.getChatCompletionWithConfig(chatConfig, {
  messages: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: "Summarize SAP BTP in one sentence." },
  ],
});
```

---

### `getRagResponseWithConfig(input, tableName, embeddingColumnName, contentColumn, chatInstruction, embeddingConfig, chatConfig, context?, topK?, algoName?)`

Execute a full RAG pipeline: embed → similarity search → chat completion.

| Parameter             | Type              | Default               | Description                                                     |
| --------------------- | ----------------- | --------------------- | --------------------------------------------------------------- |
| `input`               | `string`          |                       | User query text.                                                |
| `tableName`           | `string`          |                       | HANA table with vector embeddings.                              |
| `embeddingColumnName` | `string`          |                       | Column with embedding vectors.                                  |
| `contentColumn`       | `string`          |                       | Column with document text.                                      |
| `chatInstruction`     | `string`          |                       | System prompt. Similar content is injected in triple backticks. |
| `embeddingConfig`     | `EmbeddingConfig` |                       | Embedding model config.                                         |
| `chatConfig`          | `ChatConfig`      |                       | Chat model config.                                              |
| `context`             | `unknown[]`       | `undefined`           | Optional conversation history.                                  |
| `topK`                | `number`          | `3`                   | Number of similar documents to retrieve.                        |
| `algoName`            | `string`          | `"COSINE_SIMILARITY"` | `"COSINE_SIMILARITY"` or `"L2DISTANCE"`.                        |

**Returns:** `RagResponse` — `{ completion, additionalContents }`.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");

const result: RagResponse = await plugin.getRagResponseWithConfig(
  "What is SAP HANA?",
  "DOCUMENTS",
  "EMBEDDING",
  "CONTENT",
  "Answer based on the following context.",
  embeddingConfig,
  chatConfig,
  undefined, // no conversation history
  5, // top 5 results
  "COSINE_SIMILARITY"
);

console.log(result.completion); // Chat model response
console.log(result.additionalContents); // Similar documents with scores
```

---

### `similaritySearch(tableName, embeddingColumnName, contentColumn, embedding, algoName, topK)`

Perform vector similarity search against SAP HANA Cloud.

| Parameter             | Type       | Description                              |
| --------------------- | ---------- | ---------------------------------------- |
| `tableName`           | `string`   | HANA table with embeddings.              |
| `embeddingColumnName` | `string`   | Column with embedding vectors.           |
| `contentColumn`       | `string`   | Column with document text.               |
| `embedding`           | `number[]` | Query embedding vector.                  |
| `algoName`            | `string`   | `"COSINE_SIMILARITY"` or `"L2DISTANCE"`. |
| `topK`                | `number`   | Number of results (max 10000).           |

**Returns:** `SimilaritySearchResult[]` — each with `PAGE_CONTENT` and `SCORE`.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");
const results = await plugin.similaritySearch(
  "DOCUMENTS",
  "EMBEDDING",
  "CONTENT",
  [0.12, 0.34, 0.56, 0.78],
  "COSINE_SIMILARITY",
  5
);
```

---

## Orchestration Service Methods

### `getHarmonizedChatCompletion({ clientConfig, chatCompletionConfig, getContent?, getTokenUsage?, getFinishReason? })`

Chat completion via the OrchestrationClient with optional response extraction.

| Parameter              | Type      | Default | Description                                                                                                                                                |
| ---------------------- | --------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `clientConfig`         | `object`  |         | OrchestrationClient config (model, templating, filtering). See [@sap-ai-sdk/orchestration](https://www.npmjs.com/package/@sap-ai-sdk/orchestration#usage). |
| `chatCompletionConfig` | `object`  |         | Chat completion request (messages, inputParams).                                                                                                           |
| `getContent`           | `boolean` | `false` | Return only the content string.                                                                                                                            |
| `getTokenUsage`        | `boolean` | `false` | Return only the token usage object.                                                                                                                        |
| `getFinishReason`      | `boolean` | `false` | Return only the finish reason string.                                                                                                                      |

**Returns:** Full response, or extracted part based on the first truthy flag.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");

const content = await plugin.getHarmonizedChatCompletion({
  clientConfig: {
    promptTemplating: {
      model: { name: "gpt-4o", version: "latest" },
    },
  },
  chatCompletionConfig: {
    messages: [
      { role: "system", content: "You are a helpful assistant." },
      { role: "user", content: "What is SAP BTP?" },
    ],
  },
  getContent: true,
});

console.log(content); // "SAP BTP is..."
```

---

### `getContentFilters({ type, config })`

Build a content safety filter for use with the Orchestration Service.

| Parameter | Type     | Description                                                                                                                           |
| --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `type`    | `string` | Filter provider. Currently only `"azure"` (case-insensitive).                                                                         |
| `config`  | `object` | Provider-specific config. See [@sap-ai-sdk/orchestration](https://www.npmjs.com/package/@sap-ai-sdk/orchestration#content-filtering). |

**Returns:** The constructed filter object from the SDK.

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");

const filter = await plugin.getContentFilters({
  type: "azure",
  config: { Hate: 2, Violence: 4, SelfHarm: 0, Sexual: 0 },
});

// Use in harmonized chat completion:
const response = await plugin.getHarmonizedChatCompletion({
  clientConfig: {
    promptTemplating: { model: { name: "gpt-4o" } },
    inputFiltering: { filters: [filter] },
  },
  chatCompletionConfig: {
    messages: [{ role: "user", content: "Hello" }],
  },
});
```

---

## Deprecated Methods

> These methods are retained for backward compatibility. They use environment-based
> Azure OpenAI configuration and will be removed in a future major version.

| Method                       | Replacement                                    |
| ---------------------------- | ---------------------------------------------- |
| `getEmbedding(input)`        | `getEmbeddingWithConfig(config, input)`        |
| `getChatCompletion(payload)` | `getChatCompletionWithConfig(config, payload)` |
| `getRagResponse(...)`        | `getRagResponseWithConfig(...)`                |
