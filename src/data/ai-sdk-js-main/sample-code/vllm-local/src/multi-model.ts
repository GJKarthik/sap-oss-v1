// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Multi-Model Router Example
 *
 * Demonstrates routing requests to different models based on tasks.
 *
 * Run: npx ts-node src/multi-model.ts
 */

import {
  VllmChatClient,
  ModelRouter,
  HealthMonitor,
  createHealthMonitorForRouter,
} from '@sap-ai-sdk/vllm';

async function main() {
  console.log('🔀 Multi-Model Router Example\n');

  // Create router
  const router = new ModelRouter({
    defaultModel: 'general',
    loadBalanceStrategy: 'round-robin',
    skipUnhealthy: true,
  });

  // Register general-purpose model
  router.registerModel(
    'general',
    new VllmChatClient({
      endpoint: process.env.VLLM_ENDPOINT || 'http://localhost:8000',
      model: 'meta-llama/Llama-3.1-8B-Instruct',
    }),
    {
      priority: 1,
      weight: 2,
      tags: ['chat', 'general'],
    }
  );

  // Register code model (if available)
  if (process.env.VLLM_CODE_ENDPOINT) {
    router.registerModel(
      'code',
      new VllmChatClient({
        endpoint: process.env.VLLM_CODE_ENDPOINT,
        model: 'codellama/CodeLlama-7b-Instruct-hf',
      }),
      {
        priority: 2,
        tags: ['code', 'programming'],
      }
    );

    // Map tasks to code model
    router.setTaskMapping('code', [
      'code-generation',
      'code-review',
      'code-explanation',
    ]);
  }

  // Set up health monitoring
  const monitor = createHealthMonitorForRouter(router, {
    interval: 30000, // Check every 30s
    failureThreshold: 3,
    recoveryThreshold: 2,
  });

  // Listen for health changes
  monitor.onHealthChange((name, wasHealthy, isHealthy, info) => {
    if (isHealthy !== wasHealthy) {
      console.log(
        `⚠️  Model "${name}" health changed: ${wasHealthy} → ${isHealthy}`
      );
      if (info.error) {
        console.log(`   Error: ${info.error}`);
      }
    }
  });

  // Start monitoring
  monitor.start();
  console.log('🏥 Health monitor started\n');

  // Example 1: General chat
  console.log('--- General Chat ---\n');
  console.log('📤 Using default model for general chat');

  const generalResponse = await router.chat([
    { role: 'user', content: 'What is the best way to learn a new language?' },
  ]);
  console.log('📥 Response:', generalResponse.choices[0].message.content);

  // Example 2: Task-based routing
  console.log('\n--- Task-Based Routing ---\n');

  if (router.getClientByName('code')) {
    console.log('📤 Using code model for code generation task');
    const codeResponse = await router.chat(
      [{ role: 'user', content: 'Write a Python function to calculate fibonacci' }],
      { task: 'code-generation' }
    );
    console.log('📥 Code Response:', codeResponse.choices[0].message.content);
  } else {
    console.log('ℹ️  Code model not configured, using general model');
    const codeResponse = await router.chat([
      { role: 'user', content: 'Explain what a fibonacci sequence is' },
    ]);
    console.log('📥 Response:', codeResponse.choices[0].message.content);
  }

  // Example 3: Check stats
  console.log('\n--- Model Stats ---\n');
  const stats = router.getAllStats();
  for (const [name, stat] of Object.entries(stats)) {
    console.log(`📊 ${name}:`);
    console.log(`   Requests: ${stat.requestCount}`);
    console.log(`   Errors: ${stat.errorCount}`);
    console.log(`   Avg Latency: ${stat.averageLatencyMs.toFixed(0)}ms`);
    console.log(`   Status: ${stat.status}`);
  }

  // Example 4: Health status
  console.log('\n--- Health Status ---\n');
  const health = monitor.getAggregateHealth();
  console.log(`🏥 Overall Health: ${health.healthy}/${health.total} models healthy`);
  console.log(`   Percentage: ${(health.percentage * 100).toFixed(0)}%`);

  // Clean up
  monitor.stop();
  console.log('\n✅ Done!');
}

main().catch(console.error);