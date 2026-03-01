import { createLogger } from '@sap-cloud-sdk/util';
const logger = createLogger({
    package: 'foundation-models',
    messageContext: 'azure-openai-embedding-response'
});
/**
 * Azure OpenAI embedding response.
 */
export class AzureOpenAiEmbeddingResponse {
    rawResponse;
    /**
     * The embedding response.
     */
    _data;
    constructor(rawResponse) {
        this.rawResponse = rawResponse;
        this._data = rawResponse.data;
    }
    /**
     * Parses the Azure OpenAI response and returns the embedding.
     * @param dataIndex - The index of the data to parse.
     * @returns The embedding vector.
     */
    getEmbedding(dataIndex = 0) {
        this.logInvalidDataIndex(dataIndex);
        return this._data.data[dataIndex]?.embedding;
    }
    /**
     * Parses the Azure OpenAI response and returns all embeddings.
     * @returns The embedding vectors.
     */
    getEmbeddings() {
        return this._data.data.map(({ embedding }) => embedding);
    }
    logInvalidDataIndex(dataIndex) {
        if (dataIndex < 0 || dataIndex >= this._data.data.length) {
            logger.error(`Data index ${dataIndex} is out of bounds.`);
        }
    }
}
//# sourceMappingURL=azure-openai-embedding-response.js.map