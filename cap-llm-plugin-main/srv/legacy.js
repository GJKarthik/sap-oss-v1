// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Legacy methods for backward compatibility.
 *
 * These methods are deprecated and will be removed in a future major version.
 * They only support Azure OpenAI models via environment-based configuration
 * (cds.env.requires["GENERATIVE_AI_HUB"]).
 *
 * Use the *WithConfig() variants instead:
 *   - getEmbedding()       → getEmbeddingWithConfig()
 *   - getChatCompletion()  → getChatCompletionWithConfig()
 *   - getRagResponse()     → getRagResponseWithConfig()
 */

const cds = require("@sap/cds");

/**
 * Get vector embeddings using environment-based Azure OpenAI configuration.
 *
 * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getEmbeddingWithConfig} instead,
 * which supports multiple models and explicit configuration.
 *
 * @param {object} input - The input string to be embedded.
 * @returns {object} Returns the vector embeddings.
 */
async function getEmbedding(input) {
  try {
    console.warn(
      `[DEPRECATED] getEmbedding() is deprecated and will be removed in a future version. ` +
        `Use getEmbeddingWithConfig() instead, which supports multiple models.`
    );
    const EMBEDDING_MODEL_DESTINATION_NAME = cds.env.requires["GENERATIVE_AI_HUB"]["EMBEDDING_MODEL_DESTINATION_NAME"];
    const EMBEDDING_MODEL_DEPLOYMENT_URL = cds.env.requires["GENERATIVE_AI_HUB"]["EMBEDDING_MODEL_DEPLOYMENT_URL"];
    const EMBEDDING_MODEL_RESOURCE_GROUP = cds.env.requires["GENERATIVE_AI_HUB"]["EMBEDDING_MODEL_RESOURCE_GROUP"];
    const EMBEDDING_MODEL_API_VERSION = cds.env.requires["GENERATIVE_AI_HUB"]["EMBEDDING_MODEL_API_VERSION"];

    const destService = await cds.connect.to(`${EMBEDDING_MODEL_DESTINATION_NAME}`);
    const payload = {
      input: input,
    };
    const headers = {
      "Content-Type": "application/json",
      "AI-Resource-Group": `${EMBEDDING_MODEL_RESOURCE_GROUP}`,
    };

    const response = await destService.send({
      query: `POST ${EMBEDDING_MODEL_DEPLOYMENT_URL}/embeddings?api-version=${EMBEDDING_MODEL_API_VERSION}`,
      data: payload,
      headers: headers,
    });
    if (response && response.data) {
      return response.data[0].embedding;
    } else {
      const error_message = "Empty response or response data.";
      console.log(error_message);
      throw new Error(error_message);
    }
  } catch (error) {
    console.log("Error getting embedding response:", error);
    throw error;
  }
}

/**
 * Perform chat completion using environment-based Azure OpenAI configuration.
 *
 * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getChatCompletionWithConfig} instead,
 * which supports GPT, Gemini, and Claude models with explicit configuration.
 *
 * @param {object} payload - The payload for the chat completion model.
 * @returns {object} The chat completion results from the model.
 */
async function getChatCompletion(payload) {
  try {
    console.warn(
      `[DEPRECATED] getChatCompletion() is deprecated and will be removed in a future version. ` +
        `Use getChatCompletionWithConfig() instead, which supports multiple models.`
    );
    const CHAT_MODEL_DESTINATION_NAME = cds.env.requires["GENERATIVE_AI_HUB"]["CHAT_MODEL_DESTINATION_NAME"];
    const CHAT_MODEL_DEPLOYMENT_URL = cds.env.requires["GENERATIVE_AI_HUB"]["CHAT_MODEL_DEPLOYMENT_URL"];
    const CHAT_MODEL_RESOURCE_GROUP = cds.env.requires["GENERATIVE_AI_HUB"]["CHAT_MODEL_RESOURCE_GROUP"];
    const CHAT_MODEL_API_VERSION = cds.env.requires["GENERATIVE_AI_HUB"]["CHAT_MODEL_API_VERSION"];

    const destService = await cds.connect.to(`${CHAT_MODEL_DESTINATION_NAME}`);
    const headers = {
      "Content-Type": "application/json",
      "AI-Resource-Group": `${CHAT_MODEL_RESOURCE_GROUP}`,
    };

    const response = await destService.send({
      query: `POST ${CHAT_MODEL_DEPLOYMENT_URL}/chat/completions?api-version=${CHAT_MODEL_API_VERSION}`,
      data: payload,
      headers: headers,
    });

    if (response && response.choices) {
      return response.choices[0].message;
    } else {
      const error_message = "Empty response or response data.";
      throw new Error(error_message);
    }
  } catch (error) {
    console.log("Error getting chat completion response:", error);
    throw error;
  }
}

/**
 * Retrieve RAG response using environment-based Azure OpenAI configuration.
 *
 * @deprecated Since v1.4.0. Use {@link CAPLLMPlugin#getRagResponseWithConfig} instead,
 * which supports multiple embedding and chat models with explicit configuration.
 *
 * @param {Function} getEmbeddingFn - Bound reference to this.getEmbedding.
 * @param {Function} similaritySearchFn - Bound reference to this.similaritySearch.
 * @param {Function} getChatCompletionFn - Bound reference to this.getChatCompletion.
 * @param {string} input - User input.
 * @param {string} tableName - The HANA Cloud table with vector embeddings.
 * @param {string} embeddingColumnName - The column with embeddings.
 * @param {string} contentColumn - The column with page content.
 * @param {string} chatInstruction - The system prompt instruction.
 * @param {object} context - Optional chat history.
 * @param {number} topK - Number of entries to return. Default 3.
 * @param {string} algoName - Similarity algorithm. Default 'COSINE_SIMILARITY'.
 * @param {object} chatParams - Optional additional chat params.
 * @returns {object} The RAG response with completion and additionalContents.
 */
async function getRagResponse(
  getEmbeddingFn,
  similaritySearchFn,
  getChatCompletionFn,
  input,
  tableName,
  embeddingColumnName,
  contentColumn,
  chatInstruction,
  context,
  topK = 3,
  algoName = "COSINE_SIMILARITY",
  chatParams
) {
  try {
    console.warn(
      `[DEPRECATED] getRagResponse() is deprecated and will be removed in a future version. ` +
        `Use getRagResponseWithConfig() instead, which supports multiple models.`
    );
    const queryEmbedding = await getEmbeddingFn(input);
    const similaritySearchResults = await similaritySearchFn(
      tableName,
      embeddingColumnName,
      contentColumn,
      queryEmbedding,
      algoName,
      topK
    );
    const similarContent = similaritySearchResults.map((obj) => obj.PAGE_CONTENT);
    const additionalContents = similaritySearchResults.map((obj) => {
      return {
        score: obj.SCORE,
        pageContent: obj.PAGE_CONTENT,
      };
    });
    let messagePayload = [
      {
        role: "system",
        content: ` ${chatInstruction} \`\`\` ${similarContent} \`\`\` `,
      },
    ];

    const userQuestion = [
      {
        role: "user",
        content: `${input}`,
      },
    ];

    if (typeof context !== "undefined" && context !== null && context.length > 0) {
      console.log("Using the context parameter passed.");
      messagePayload.push(...context);
    }

    messagePayload.push(...userQuestion);

    let payload = {
      messages: messagePayload,
    };
    if (chatParams !== null && chatParams !== undefined && Object.keys(chatParams).length > 0) {
      console.log("Using the chatParams parameter passed.");
      payload = Object.assign(payload, chatParams);
    }
    const chatCompletionResp = await getChatCompletionFn(payload);

    const ragResp = {
      completion: chatCompletionResp,
      additionalContents: additionalContents,
    };

    return ragResp;
  } catch (error) {
    console.log("Error during execution:", error);
    throw error;
  }
}

module.exports = {
  getEmbedding,
  getChatCompletion,
  getRagResponse,
};
