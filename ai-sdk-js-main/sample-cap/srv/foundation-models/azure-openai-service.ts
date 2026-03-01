// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { AzureOpenAiChatClient } from '@sap-ai-sdk/foundation-models';

interface ChatMessage {
  role: unknown;
  content: string;
}

interface ChatCompletionRequest {
  data?: {
    messages?: unknown;
  };
}

const MAX_MESSAGES = 100;
const MAX_CONTENT_CHARS = 20000;

export default class AzureOpenAiService {
  async chatCompletion(req: ChatCompletionRequest) {
    const rawMessages = req?.data?.messages;
    if (!Array.isArray(rawMessages) || rawMessages.length === 0) {
      throw new Error('chatCompletion requires a non-empty messages array.');
    }

    const messages = rawMessages
      .filter((entry): entry is ChatMessage =>
        !!entry &&
        typeof entry === 'object' &&
        typeof (entry as { content?: unknown }).content === 'string'
      )
      .map(message => {
        const role = typeof message.role === 'string' ? message.role.toLowerCase() : '';
        if (role !== 'system' && role !== 'user' && role !== 'assistant') {
          return null;
        }
        return {
          role,
          content: message.content
        };
      })
      .filter(
        (message): message is { role: 'system' | 'user' | 'assistant'; content: string } =>
          message !== null
      )
      .slice(0, MAX_MESSAGES)
      .map(message => ({
        role: message.role,
        content: message.content.slice(0, MAX_CONTENT_CHARS)
      }));

    if (messages.length === 0) {
      throw new Error('chatCompletion requires messages with string role and content.');
    }

    try {
      const response = await new AzureOpenAiChatClient('gpt-4o').run({
        messages
      });
      return response.getContent();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`Azure OpenAI chat completion failed: ${message}`);
    }
  }
}
