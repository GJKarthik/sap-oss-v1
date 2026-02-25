/**
 * ModelRouter tests.
 */

import {
  ModelRouter,
  type RouterModelConfig,
  type ModelRouterConfig,
  type TaskType,
  type ModelStatus,
  type LoadBalanceStrategy,
  createLoadBalancedRouter,
  createTaskRouter,
} from '../src/model-router.js';

// Mock VllmChatClient
jest.mock('../src/vllm-client.js', () => ({
  VllmChatClient: jest.fn().mockImplementation((config) => ({
    config,
    chat: jest.fn().mockResolvedValue({
      id: 'test-response',
      model: config.model,
      choices: [{ message: { role: 'assistant', content: 'Hello' } }],
    }),
  })),
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

describe('ModelRouter', () => {
  describe('constructor', () => {
    it('should create router with single model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      expect(router.size).toBe(1);
      expect(router.listModels()).toEqual(['llama']);
    });

    it('should create router with multiple models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama'),
          createModelConfig('codellama'),
          createModelConfig('mistral'),
        ],
      });

      expect(router.size).toBe(3);
      expect(router.listModels()).toEqual(['llama', 'codellama', 'mistral']);
    });

    it('should set default model to first if not specified', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
      });

      expect(router.getDefaultModelName()).toBe('llama');
    });

    it('should set specified default model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
        defaultModel: 'mistral',
      });

      expect(router.getDefaultModelName()).toBe('mistral');
    });

    it('should skip disabled models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama'),
          createModelConfig('disabled', { enabled: false }),
        ],
      });

      expect(router.size).toBe(1);
      expect(router.listModels()).toEqual(['llama']);
    });

    it('should set up task mappings from config', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('codellama')],
        taskMapping: {
          chat: 'llama',
          code: 'codellama',
        },
      });

      expect(router.listModelsForTask('chat')).toEqual(['llama']);
      expect(router.listModelsForTask('code')).toEqual(['codellama']);
    });

    it('should set up task mappings from model config', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama', { tasks: ['chat', 'creative'] }),
          createModelConfig('codellama', { tasks: ['code'] }),
        ],
      });

      expect(router.listModelsForTask('chat')).toEqual(['llama']);
      expect(router.listModelsForTask('creative')).toEqual(['llama']);
      expect(router.listModelsForTask('code')).toEqual(['codellama']);
    });
  });

  describe('registerModel', () => {
    it('should register new model', () => {
      const router = new ModelRouter({ models: [] });
      router.registerModel(createModelConfig('llama'));

      expect(router.size).toBe(1);
      expect(router.listModels()).toEqual(['llama']);
    });

    it('should register task mappings for model', () => {
      const router = new ModelRouter({ models: [] });
      router.registerModel(createModelConfig('llama', { tasks: ['chat'] }));

      expect(router.listModelsForTask('chat')).toEqual(['llama']);
    });

    it('should not register disabled model', () => {
      const router = new ModelRouter({ models: [] });
      router.registerModel(createModelConfig('llama', { enabled: false }));

      expect(router.size).toBe(0);
    });
  });

  describe('removeModel', () => {
    it('should remove existing model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
      });

      const removed = router.removeModel('llama');

      expect(removed).toBe(true);
      expect(router.size).toBe(1);
      expect(router.listModels()).toEqual(['mistral']);
    });

    it('should return false for non-existent model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      const removed = router.removeModel('nonexistent');

      expect(removed).toBe(false);
      expect(router.size).toBe(1);
    });

    it('should remove task mappings for removed model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama', { tasks: ['chat'] })],
      });

      router.removeModel('llama');

      expect(router.listModelsForTask('chat')).toEqual([]);
    });

    it('should update default model when removing default', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
        defaultModel: 'llama',
      });

      router.removeModel('llama');

      expect(router.getDefaultModelName()).toBe('mistral');
    });
  });

  describe('getClient', () => {
    it('should return client for task', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama', { tasks: ['chat'] })],
      });

      const client = router.getClient('chat');

      expect(client).toBeDefined();
    });

    it('should return default client for unmapped task', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
        defaultModel: 'llama',
      });

      const client = router.getClient('analysis');

      expect(client).toBeDefined();
    });

    it('should throw for unmapped task without default', () => {
      const router = new ModelRouter({
        models: [],
      });

      expect(() => router.getClient('chat')).toThrow('No model available for task');
    });
  });

  describe('getClientByName', () => {
    it('should return client by name', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
      });

      const client = router.getClientByName('mistral');

      expect(client).toBeDefined();
    });

    it('should throw for non-existent model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      expect(() => router.getClientByName('nonexistent')).toThrow('Model not found');
    });
  });

  describe('getDefaultClient', () => {
    it('should return default client', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      const client = router.getDefaultClient();

      expect(client).toBeDefined();
    });

    it('should throw when no default configured', () => {
      const router = new ModelRouter({ models: [] });

      expect(() => router.getDefaultClient()).toThrow('No default model configured');
    });
  });

  describe('setDefaultModel', () => {
    it('should change default model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
      });

      router.setDefaultModel('mistral');

      expect(router.getDefaultModelName()).toBe('mistral');
    });

    it('should throw for non-existent model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      expect(() => router.setDefaultModel('nonexistent')).toThrow('Model not found');
    });
  });

  describe('setTaskMapping', () => {
    it('should set single model for task', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      router.setTaskMapping('chat', 'llama');

      expect(router.listModelsForTask('chat')).toEqual(['llama']);
    });

    it('should set multiple models for task', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama'), createModelConfig('mistral')],
      });

      router.setTaskMapping('chat', ['llama', 'mistral']);

      expect(router.listModelsForTask('chat')).toEqual(['llama', 'mistral']);
    });

    it('should throw for non-existent model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      expect(() => router.setTaskMapping('chat', 'nonexistent')).toThrow('Model not found');
    });
  });

  describe('load balancing - round-robin', () => {
    it('should rotate through models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-0'),
          createModelConfig('model-1'),
          createModelConfig('model-2'),
        ],
        loadBalanceStrategy: 'round-robin',
      });

      // Get 6 clients - should rotate twice through all 3
      const names: string[] = [];
      for (let i = 0; i < 6; i++) {
        const client = router.getBalancedClient();
        const state = router.getModelConfig(router.listModels().find(
          (n) => router.getClientByName(n) === client
        ) ?? '');
        names.push(state?.name ?? '');
      }

      expect(names).toEqual(['model-0', 'model-1', 'model-2', 'model-0', 'model-1', 'model-2']);
    });
  });

  describe('load balancing - priority', () => {
    it('should select highest priority model', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('low', { priority: 1 }),
          createModelConfig('high', { priority: 10 }),
          createModelConfig('medium', { priority: 5 }),
        ],
        loadBalanceStrategy: 'priority',
      });

      const client = router.getBalancedClient();
      const config = router.getModelConfig('high');

      expect(router.getClientByName('high')).toBe(client);
    });
  });

  describe('load balancing - random', () => {
    it('should return a client (random)', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('model-0'),
          createModelConfig('model-1'),
        ],
        loadBalanceStrategy: 'random',
      });

      const client = router.getBalancedClient();

      expect(client).toBeDefined();
    });
  });

  describe('model status tracking', () => {
    it('should set model status', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      router.setModelStatus('llama', 'healthy');

      expect(router.getModelStatus('llama')).toBe('healthy');
    });

    it('should record success and update stats', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      router.recordSuccess('llama', 100);
      router.recordSuccess('llama', 200);

      const stats = router.getModelStats('llama');
      expect(stats?.requestCount).toBe(2);
      expect(stats?.averageLatency).toBe(150);
      expect(stats?.status).toBe('healthy');
    });

    it('should record errors and degrade status', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      const error = new Error('Connection failed');
      router.recordError('llama', error);
      router.recordError('llama', error);

      const stats = router.getModelStats('llama');
      expect(stats?.errorCount).toBe(2);
      expect(stats?.status).toBe('unhealthy');
    });

    it('should skip unhealthy models in load balancing', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('healthy'),
          createModelConfig('unhealthy'),
        ],
        skipUnhealthy: true,
      });

      router.setModelStatus('healthy', 'healthy');
      router.setModelStatus('unhealthy', 'unhealthy');

      // All selections should return the healthy model
      for (let i = 0; i < 5; i++) {
        const client = router.getBalancedClient();
        expect(router.getClientByName('healthy')).toBe(client);
      }
    });
  });

  describe('model configuration', () => {
    it('should return model config', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama', { priority: 5 })],
      });

      const config = router.getModelConfig('llama');

      expect(config?.name).toBe('llama');
      expect(config?.priority).toBe(5);
    });

    it('should return undefined for non-existent model', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      expect(router.getModelConfig('nonexistent')).toBeUndefined();
    });
  });

  describe('model tags', () => {
    it('should list models by tag', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama', { tags: ['production', 'fast'] }),
          createModelConfig('mistral', { tags: ['production'] }),
          createModelConfig('test', { tags: ['development'] }),
        ],
      });

      expect(router.listModelsByTag('production')).toEqual(['llama', 'mistral']);
      expect(router.listModelsByTag('fast')).toEqual(['llama']);
      expect(router.listModelsByTag('development')).toEqual(['test']);
    });
  });

  describe('getAllStats', () => {
    it('should return stats for all models', () => {
      const router = new ModelRouter({
        models: [
          createModelConfig('llama'),
          createModelConfig('mistral'),
        ],
      });

      router.recordSuccess('llama', 100);
      router.recordSuccess('mistral', 200);

      const stats = router.getAllStats();

      expect(stats).toHaveLength(2);
      expect(stats.map((s) => s.name)).toEqual(['llama', 'mistral']);
    });
  });

  describe('resetStats', () => {
    it('should reset all statistics', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama')],
      });

      router.recordSuccess('llama', 100);
      router.recordError('llama', new Error('test'));
      router.resetStats();

      const stats = router.getModelStats('llama');
      expect(stats?.requestCount).toBe(0);
      expect(stats?.errorCount).toBe(0);
    });
  });

  describe('getTaskMappings', () => {
    it('should return copy of task mappings', () => {
      const router = new ModelRouter({
        models: [createModelConfig('llama', { tasks: ['chat', 'creative'] })],
      });

      const mappings = router.getTaskMappings();

      expect(mappings.get('chat')).toEqual(['llama']);
      expect(mappings.get('creative')).toEqual(['llama']);
    });
  });
});

describe('createLoadBalancedRouter', () => {
  it('should create router with multiple endpoints', () => {
    const router = createLoadBalancedRouter(
      ['http://vllm-1:8000', 'http://vllm-2:8000', 'http://vllm-3:8000'],
      'llama-70b'
    );

    expect(router.size).toBe(3);
  });
});

describe('createTaskRouter', () => {
  it('should create router with task-specific models', () => {
    const router = createTaskRouter({
      chat: createModelConfig('llama'),
      code: createModelConfig('codellama'),
    });

    expect(router.size).toBe(2);
    expect(router.getTaskMappings().get('chat')).toEqual(['llama']);
    expect(router.getTaskMappings().get('code')).toEqual(['codellama']);
  });
});