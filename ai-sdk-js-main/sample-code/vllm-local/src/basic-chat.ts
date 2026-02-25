/**
 * Basic Chat Example
 *
 * Demonstrates simple chat completion with vLLM.
 *
 * Run: npx ts-node src/basic-chat.ts
 */

import { VllmChatClient } from '@sap-ai-sdk/vllm';

async function main() {
  // Create client
  const client = new VllmChatClient({
    endpoint: process.env.VLLM_ENDPOINT || 'http://localhost:8000',
    model: process.env.VLLM_MODEL || 'meta-llama/Llama-3.1-8B-Instruct',
    apiKey: process.env.VLLM_API_KEY,
  });

  console.log('🚀 Basic Chat Example\n');

  // Simple chat
  console.log('📤 Sending message: "What is the capital of France?"');

  const response = await client.chat([
    { role: 'system', content: 'You are a helpful assistant. Be concise.' },
    { role: 'user', content: 'What is the capital of France?' },
  ]);

  console.log('📥 Response:', response.choices[0].message.content);
  console.log('\n📊 Usage:');
  console.log(`   Prompt tokens: ${response.usage.promptTokens}`);
  console.log(`   Completion tokens: ${response.usage.completionTokens}`);
  console.log(`   Total tokens: ${response.usage.totalTokens}`);

  // Multi-turn conversation
  console.log('\n--- Multi-turn Conversation ---\n');

  const messages = [
    { role: 'system' as const, content: 'You are a helpful math tutor.' },
    { role: 'user' as const, content: 'What is 2 + 2?' },
  ];

  console.log('📤 User: What is 2 + 2?');
  const response1 = await client.chat(messages);
  console.log('📥 Assistant:', response1.choices[0].message.content);

  // Continue conversation
  messages.push({
    role: 'assistant' as const,
    content: response1.choices[0].message.content!,
  });
  messages.push({
    role: 'user' as const,
    content: 'Now multiply that by 3',
  });

  console.log('📤 User: Now multiply that by 3');
  const response2 = await client.chat(messages);
  console.log('📥 Assistant:', response2.choices[0].message.content);

  // With parameters
  console.log('\n--- With Custom Parameters ---\n');

  const creativeResponse = await client.chat(
    [{ role: 'user', content: 'Write a haiku about programming' }],
    {
      temperature: 0.9, // Higher for more creativity
      maxTokens: 50,
    }
  );

  console.log('📥 Creative Response:');
  console.log(creativeResponse.choices[0].message.content);

  console.log('\n✅ Done!');
}

main().catch(console.error);