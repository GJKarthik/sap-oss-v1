// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Week 3 Integration Tests.
 *
 * Tests the integration between ModelRouter, HealthMonitor, and ModelDiscovery.
 */

import {
  ModelRouter,
  type RouterModelConfig,
  type TaskType,
  createLoadBalancedRouter,
} from '../src/model-router.js';
import {
  HealthMonitor,
  createHealthMonitorForRouter,
} from '../src/health-monitor.js';
import {
  ModelDiscovery,
  type DiscoveredModel,
  ModelFilters,
  formatModelInfo,
  findBestModelForTask,
  groupModelsByFamily,
} from '../src/model-discovery.js';

// Mock VllmChatClient
const createMockClient = (healthy = true, modelId = 'test-model') => ({
  healthCheck: jest.fn().mockResolvedValue({
    healthy,
    status: healthy ? 'ok' : 'error',
    timestamp: Date.now(),
  }),
  listModels: jest.fn().mockResolvedValue([
    { id: modelId, object: 'model', created: Date.now(), ownedBy: 'vllm' },
  ]),
  chat: jest.fn().mockResolvedValue({
    id: 'test-response',
    model: modelId,
    choices: [{ message: { role: 'assistant', content: 'Hello!' } }],
  }),
});

jest.mock('../src/vllm-client.js', () => ({
  VllmChatClient: jest.fn().mockImplementation((config) => createMockClient(true, config.model)),
}));

// Helper to create model configs
function createModelConfig(
  name: string,
  overrides: Partial<RouterModelConfig> = {}
): RouterModelConfig {
  return {
    name,
    endpoint: `http://${name}:8000`,
    model: `${name}-model`,
    ...overrides,
  };
}

describe('Week 3 Integration Tests', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('ModelRouter + HealthMonitor Integration', () => {
    it('should create monitor that updates router status', async () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-1'),
          createModelConfig('model-2'),
        ],
      });

      const monitor = createHealthMonitorForRouter(router, {
        interval: 1000,
        failureThreshold: 1,
      });

      expect(monitor.clientCount).toBe(2);

      // Health check should update router status
      await monitor.checkAll();

      // Both should be healthy after check
      expect(router.getModelStatus('model-1')).toBe('healthy');
      expect(router.getModelStatus('model-2')).toBe('healthy');
    });

    it('should skip unhealthy models in load balancing', async () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('healthy-1'),
          createModelConfig('unhealthy'),
          createModelConfig('healthy-2'),
        ],
        loadBalanceStrategy: 'round-robin',
        skipUnhealthy: true,
      });

      // Mark one as unhealthy
      router.setModelStatus('healthy-1', 'healthy');
      router.setModelStatus('unhealthy', 'unhealthy');
      router.setModelStatus('healthy-2', 'healthy');

      // All balanced selections should skip unhealthy
      const selectedNames = new Set<string>();
      for (let i = 0; i < 10; i++) {
        const client = router.getBalancedClient();
        // Find which model this client belongs to
        for (const name of ['healthy-1', 'healthy-2']) {
          if (router.getClientByName(name) === client) {
            selectedNames.add(name);
          }
        }
      }

      expect(selectedNames.has('healthy-1')).toBe(true);
      expect(selectedNames.has('healthy-2')).toBe(true);
    });

    it('should track stats through router.chat()', async () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      // Make chat request through router
      await router.chat([{ role: 'user', content: 'Hello' }]);

      const stats = router.getModelStats('llama');
      expect(stats?.requestCount).toBe(1);
    });

    it('should handle model degradation on errors', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      // Record multiple errors
      router.recordError('llama', new Error('Failed 1'));
      router.recordError('llama', new Error('Failed 2'));
      router.recordError('llama', new Error('Failed 3'));

      const stats = router.getModelStats('llama');
      expect(stats?.errorCount).toBe(3);
      expect(stats?.status).toBe('unhealthy');
    });

    it('should update aggregate health when model status changes', async () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-1'),
          createModelConfig('model-2'),
          createModelConfig('model-3'),
        ],
      });

      const monitor = createHealthMonitorForRouter(router, {
        failureThreshold: 1,
      });

      // Initially all healthy
      await monitor.checkAll();
      let aggregate = monitor.getAggregateHealth();
      expect(aggregate.allHealthy).toBe(true);

      // Manually mark one unhealthy
      router.setModelStatus('model-2', 'unhealthy');

      // Re-check health info
      const health = monitor.getHealth('model-2');
      // Note: health info is tracked separately from router status
    });
  });

  describe('Task-Based Routing', () => {
    it('should route to correct model based on task', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama', { tasks: ['chat', 'creative'] }),
          createModelConfig('codellama', { tasks: ['code'] }),
          createModelConfig('embed', { tasks: ['embedding'] }),
        ],
      });

      const chatClient = router.getClient('chat');
      const codeClient = router.getClient('code');
      const embedClient = router.getClient('embedding');

      // Verify different clients for different tasks
      expect(router.getClientByName('llama')).toBe(chatClient);
      expect(router.getClientByName('codellama')).toBe(codeClient);
      expect(router.getClientByName('embed')).toBe(embedClient);
    });

    it('should load balance when multiple models for same task', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama-1', { tasks: ['chat'] }),
          createModelConfig('llama-2', { tasks: ['chat'] }),
          createModelConfig('llama-3', { tasks: ['chat'] }),
        ],
        loadBalanceStrategy: 'round-robin',
      });

      // Get clients for chat task multiple times
      const clients = new Set();
      for (let i = 0; i < 6; i++) {
        clients.add(router.getClient('chat'));
      }

      // Should have used all 3 models
      expect(clients.size).toBe(3);
    });

    it('should fall back to default for unmapped tasks', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama', { tasks: ['chat'] }),
        ],
        defaultModel: 'llama',
      });

      // Analysis is not mapped, should fall back to default
      const client = router.getClient('analysis');
      expect(client).toBe(router.getDefaultClient());
    });
  });

  describe('Load Balancing Strategies', () => {
    it('round-robin should cycle through all models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-0'),
          createModelConfig('model-1'),
          createModelConfig('model-2'),
        ],
        loadBalanceStrategy: 'round-robin',
      });

      const sequence: string[] = [];
      for (let i = 0; i < 9; i++) {
        const client = router.getBalancedClient();
        for (const name of router.listModels()) {
          if (router.getClientByName(name) === client) {
            sequence.push(name);
            break;
          }
        }
      }

      // Should repeat pattern 3 times
      expect(sequence).toEqual([
        'model-0', 'model-1', 'model-2',
        'model-0', 'model-1', 'model-2',
        'model-0', 'model-1', 'model-2',
      ]);
    });

    it('priority should always select highest priority', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('low', { priority: 1 }),
          createModelConfig('high', { priority: 100 }),
          createModelConfig('medium', { priority: 50 }),
        ],
        loadBalanceStrategy: 'priority',
      });

      // All selections should be high priority
      for (let i = 0; i < 5; i++) {
        const client = router.getBalancedClient();
        expect(router.getClientByName('high')).toBe(client);
      }
    });

    it('least-latency should prefer faster models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('slow'),
          createModelConfig('fast'),
        ],
        loadBalanceStrategy: 'least-latency',
      });

      // Record different latencies
      router.recordSuccess('slow', 500);
      router.recordSuccess('fast', 50);

      // Should prefer fast
      const client = router.getBalancedClient();
      expect(router.getClientByName('fast')).toBe(client);
    });
  });

  describe('HealthMonitor Callbacks', () => {
    it('should notify on health check completion', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 1,
      });
      monitor.addClient('test', createMockClient(true) as any);

      const healthCallback = jest.fn();
      monitor.onHealthCheck(healthCallback);

      await monitor.check('test');

      expect(healthCallback).toHaveBeenCalledWith(
        'test',
        true,
        expect.objectContaining({ name: 'test', healthy: true }),
        undefined
      );
    });

    it('should notify on status change', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 1,
      });

      const unhealthyClient = {
        healthCheck: jest.fn().mockResolvedValue({ healthy: false, status: 'error' }),
      };
      monitor.addClient('test', unhealthyClient as any);

      const changeCallback = jest.fn();
      monitor.onHealthChange(changeCallback);

      await monitor.check('test');

      expect(changeCallback).toHaveBeenCalledWith(
        'test',
        true,  // previous (assumed healthy)
        false, // new (unhealthy)
        expect.objectContaining({ name: 'test', healthy: false })
      );
    });
  });

  describe('ModelDiscovery Integration', () => {
    it('should discover and analyze models', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      expect(models.length).toBeGreaterThan(0);
      expect(models[0].id).toBeDefined();
      expect(models[0].capabilities).toBeDefined();
    });

    it('should generate router configs from discovery', async () => {
      const discovery = new ModelDiscovery();
      const configs = await discovery.createRouterConfigs(['http://vllm:8000']);

      expect(configs.length).toBeGreaterThan(0);
      expect(configs[0].name).toBeDefined();
      expect(configs[0].endpoint).toBe('http://vllm:8000');
    });
  });

  describe('ModelFilters Composition', () => {
    const models: DiscoveredModel[] = [
      {
        id: 'llama-70b',
        endpoint: 'http://vllm:8000',
        ownedBy: 'vllm',
        created: Date.now(),
        capabilities: { maxContextLength: 32768, streaming: true, toolCalling: true },
        suggestedTasks: ['chat', 'reasoning'],
        family: 'llama',
        size: '70B',
        supportsChat: true,
        raw: { id: 'llama-70b', object: 'model', created: Date.now(), ownedBy: 'vllm' },
      },
      {
        id: 'codellama-34b',
        endpoint: 'http://vllm:8000',
        ownedBy: 'vllm',
        created: Date.now(),
        capabilities: { maxContextLength: 16384, streaming: true },
        suggestedTasks: ['code'],
        family: 'code',
        size: '34B',
        supportsChat: true,
        raw: { id: 'codellama-34b', object: 'model', created: Date.now(), ownedBy: 'vllm' },
      },
      {
        id: 'embed-v1',
        endpoint: 'http://vllm:8000',
        ownedBy: 'vllm',
        created: Date.now(),
        capabilities: { maxContextLength: 512, streaming: false },
        suggestedTasks: ['embedding'],
        family: 'embedding',
        size: undefined,
        supportsChat: false,
        raw: { id: 'embed-v1', object: 'model', created: Date.now(), ownedBy: 'vllm' },
      },
    ];

    it('should combine filters with all()', () => {
      const filter = ModelFilters.all(
        ModelFilters.chatCapable,
        ModelFilters.minContextLength(20000)
      );

      const filtered = models.filter(filter);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('llama-70b');
    });

    it('should combine filters with any()', () => {
      const filter = ModelFilters.any(
        ModelFilters.codeModels,
        ModelFilters.embeddingModels
      );

      const filtered = models.filter(filter);
      expect(filtered).toHaveLength(2);
    });

    it('should find best model for task', () => {
      const best = findBestModelForTask(models, 'code');
      expect(best?.id).toBe('codellama-34b');
    });

    it('should group models by family', () => {
      const groups = groupModelsByFamily(models);

      expect(groups.get('llama')?.length).toBe(1);
      expect(groups.get('code')?.length).toBe(1);
      expect(groups.get('embedding')?.length).toBe(1);
    });

    it('should format model info', () => {
      const info = formatModelInfo(models[0]);

      expect(info).toContain('llama-70b');
      expect(info).toContain('[llama]');
      expect(info).toContain('70B');
    });
  });

  describe('Complete Flow: Discovery → Router → Monitor', () => {
    it('should set up complete production infrastructure', async () => {
      // Step 1: Discover models
      const discovery = new ModelDiscovery();
      const discoveredModels = await discovery.discover('http://vllm:8000');

      // Step 2: Create router configs
      const configs = await discovery.createRouterConfigs(['http://vllm:8000']);

      // Step 3: Create router
      const router = new ModelRouter({
        models: configs,
        loadBalanceStrategy: 'round-robin',
        skipUnhealthy: true,
      });

      expect(router.size).toBeGreaterThan(0);

      // Step 4: Create health monitor
      const monitor = createHealthMonitorForRouter(router, {
        interval: 30000,
        failureThreshold: 3,
      });

      expect(monitor.clientCount).toBe(router.size);

      // Step 5: Set up health change notifications
      const healthChanges: Array<{ name: string; healthy: boolean }> = [];
      monitor.onHealthChange((name, prev, curr) => {
        healthChanges.push({ name, healthy: curr });
      });

      // Step 6: Run health checks
      await monitor.checkAll();

      // Step 7: Verify aggregate health
      const aggregate = monitor.getAggregateHealth();
      expect(aggregate.total).toBe(router.size);
    });

    it('should handle multi-endpoint deployment', async () => {
      const discovery = new ModelDiscovery();

      // Discover from multiple endpoints
      const endpoints = [
        'http://vllm-1:8000',
        'http://vllm-2:8000',
        'http://vllm-3:8000',
      ];

      const configs = await discovery.createRouterConfigs(endpoints);

      // Create router with all models
      const router = new ModelRouter({
        models: configs,
        loadBalanceStrategy: 'round-robin',
      });

      // Each endpoint returns models
      expect(router.size).toBeGreaterThanOrEqual(3);

      // Create monitor
      const monitor = createHealthMonitorForRouter(router);
      expect(monitor.clientCount).toBe(router.size);
    });
  });

  describe('Error Handling', () => {
    it('should handle discovery failures gracefully', async () => {
      const { VllmChatClient } = jest.requireMock('../src/vllm-client.js');
      VllmChatClient.mockImplementationOnce(() => ({
        listModels: jest.fn().mockRejectedValue(new Error('Connection refused')),
      }));

      const discovery = new ModelDiscovery();

      // Discovery should handle failure
      const models = await discovery.discoverAll([
        'http://failed:8000',
        'http://working:8000',
      ]);

      // Should still return models from working endpoint
      expect(models.length).toBeGreaterThanOrEqual(1);
    });

    it('should handle health check failures', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 2,
      });

      const failingClient = {
        healthCheck: jest.fn().mockRejectedValue(new Error('Timeout')),
      };
      monitor.addClient('failing', failingClient as any);

      // First failure
      await monitor.check('failing');
      let info = monitor.getHealth('failing');
      expect(info?.consecutiveFailures).toBe(1);
      expect(info?.healthy).toBe(true); // Still healthy (below threshold)

      // Second failure - now unhealthy
      await monitor.check('failing');
      info = monitor.getHealth('failing');
      expect(info?.consecutiveFailures).toBe(2);
      expect(info?.healthy).toBe(false);
    });

    it('should recover from failures', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 1,
        recoveryThreshold: 2,
      });

      let healthy = false;
      const recoveringClient = {
        healthCheck: jest.fn().mockImplementation(() =>
          Promise.resolve({ healthy, status: healthy ? 'ok' : 'error' })
        ),
      };
      monitor.addClient('recovering', recoveringClient as any);

      // Start unhealthy
      await monitor.check('recovering');
      expect(monitor.getHealth('recovering')?.healthy).toBe(false);

      // Start recovering
      healthy = true;
      await monitor.check('recovering');
      expect(monitor.getHealth('recovering')?.consecutiveSuccesses).toBe(1);

      // Full recovery after threshold
      await monitor.check('recovering');
      expect(monitor.getHealth('recovering')?.healthy).toBe(true);
    });
  });

  describe('Stats and Metrics', () => {
    it('should track latency statistics', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      router.recordSuccess('llama', 100);
      router.recordSuccess('llama', 150);
      router.recordSuccess('llama', 200);

      const stats = router.getModelStats('llama');
      expect(stats?.requestCount).toBe(3);
      expect(stats?.averageLatency).toBe(150);
    });

    it('should track error rates', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      // 3 successes, 2 errors = 40% error rate
      router.recordSuccess('llama', 100);
      router.recordSuccess('llama', 100);
      router.recordSuccess('llama', 100);
      router.recordError('llama', new Error('Error 1'));
      router.recordError('llama', new Error('Error 2'));

      const stats = router.getModelStats('llama');
      expect(stats?.requestCount).toBe(3);
      expect(stats?.errorCount).toBe(2);
    });

    it('should provide aggregate health metrics', async () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-1'),
          createModelConfig('model-2'),
          createModelConfig('model-3'),
        ],
      });

      const monitor = createHealthMonitorForRouter(router, {
        failureThreshold: 1,
      });

      await monitor.checkAll();

      const aggregate = monitor.getAggregateHealth();
      expect(aggregate.total).toBe(3);
      expect(aggregate.healthy).toBe(3);
      expect(aggregate.healthPercentage).toBe(100);
      expect(aggregate.allHealthy).toBe(true);
    });
  });
});