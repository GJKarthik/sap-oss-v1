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
    parts: {
        text: string;
    }[];
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
/** Params for streamChatCompletion. */
export interface StreamChatParams {
    clientConfig: string;
    chatCompletionConfig: string;
    abortOnFilterViolation?: boolean;
}
//# sourceMappingURL=cap-llm-plugin.d.ts.map