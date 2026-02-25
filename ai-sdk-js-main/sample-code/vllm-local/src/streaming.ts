/**
 * Streaming Example
 *
 * Demonstrates real-time streaming responses from vLLM.
 *
 * Run: npx ts-node src/streaming.ts
 */

import { VllmChatClient, StreamBuilder, collectStreamContent } from '@sap-ai-sdk/vllm';

async function main() {
  const client = new VllmChatClient({
    endpoint: process.env.VLLM_ENDPOINT || 'http://localhost:8000',
    model: process.env.VLLM_MODEL || 'meta-llama/Llama-3.1-8B-Instruct',
    apiKey: process.env.VLLM_API_KEY,
  });

  console.log('🌊 Streaming Example\n');

  // Method 1: Async Iterator
  console.log('--- Method 1: Async Iterator ---\n');
  console.log('📤 Prompt: "Explain quantum computing in simple terms"\n');
  console.log('📥 Response: ');

  const stream1 = await client.chatStream([
    { role: 'user', content: 'Explain quantum computing in simple terms. Keep it brief.' },
  ]);

  for await (const chunk of stream1) {
    const content = chunk.choices[0]?.delta?.content;
    if (content) {
      process.stdout.write(content);
    }
  }
  console.log('\n');

  // Method 2: StreamBuilder with callbacks
  console.log('--- Method 2: StreamBuilder ---\n');
  console.log('📤 Prompt: "Write a short poem about AI"\n');
  console.log('📥 Response: ');

  let tokenCount = 0;
  const startTime = Date.now();

  const result = await StreamBuilder.from(client, [
    { role: 'user', content: 'Write a short poem about AI (4 lines max)' },
  ])
    .withParams({ temperature: 0.8 })
    .onContent((text) => process.stdout.write(text))
    .onChunk(() => {
      tokenCount++;
    })
    .onComplete((message, stats) => {
      console.log('\n');
      console.log('📊 Stats:');
      console.log(`   Chunks received: ${tokenCount}`);
      console.log(`   Duration: ${stats.durationMs}ms`);
      console.log(`   Time to first chunk: ${stats.timeToFirstChunkMs}ms`);
    })
    .execute();

  // Method 3: Collect full response
  console.log('\n--- Method 3: Collect Stream ---\n');
  console.log('📤 Prompt: "List 3 benefits of exercise"\n');

  const stream3 = await client.chatStream([
    { role: 'user', content: 'List 3 benefits of exercise. Be brief.' },
  ]);

  const collected = await collectStreamContent(stream3);

  console.log('📥 Collected Response:');
  console.log(collected.content);
  console.log(`\n📊 Total chunks: ${collected.chunks.length}`);
  console.log(`📊 Finish reason: ${collected.finishReason}`);

  console.log('\n✅ Done!');
}

main().catch(console.error);