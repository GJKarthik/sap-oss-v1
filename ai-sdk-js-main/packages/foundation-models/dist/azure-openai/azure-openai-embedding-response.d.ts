import type { HttpResponse } from '@sap-cloud-sdk/http-client';
import type { AzureOpenAiEmbeddingOutput } from './azure-openai-embedding-types.js';
/**
 * Azure OpenAI embedding response.
 */
export declare class AzureOpenAiEmbeddingResponse {
    readonly rawResponse: HttpResponse;
    /**
     * The embedding response.
     */
    readonly _data: AzureOpenAiEmbeddingOutput;
    constructor(rawResponse: HttpResponse);
    /**
     * Parses the Azure OpenAI response and returns the embedding.
     * @param dataIndex - The index of the data to parse.
     * @returns The embedding vector.
     */
    getEmbedding(dataIndex?: number): number[] | undefined;
    /**
     * Parses the Azure OpenAI response and returns all embeddings.
     * @returns The embedding vectors.
     */
    getEmbeddings(): number[][];
    private logInvalidDataIndex;
}
//# sourceMappingURL=azure-openai-embedding-response.d.ts.map