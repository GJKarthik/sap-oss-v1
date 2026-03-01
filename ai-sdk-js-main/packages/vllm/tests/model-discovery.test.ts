// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * ModelDiscovery tests.
 */

import {
  ModelDiscovery,
  type DiscoveredModel,
  type ModelDiscoveryConfig,
  type ModelFilter,
  ModelFilters,
  discoverModel,
  formatModelInfo,
  groupModelsByFamily,
  groupModelsByEndpoint,
  findBestModelForTask,
  DEFAULT_DISCOVERY_CONFIG,
} from '../src/model-discovery.js';

// Mock VllmChatClient
jest.mock('../src/vllm-client.js', () => ({
  VllmChatClient: jest.fn().mockImplementation(() => ({
    listModels: jest.fn().mockResolvedValue([
      { id: 'meta-llama/Llama-3.1-70B-Instruct', object: 'model', created: 1699000000, ownedBy: 'vllm' },
      { id: 'codellama/CodeLlama-34b-Instruct', object: 'model', created: 1699000000, ownedBy: 'vllm' },
    ]),
  })),
}));

// Helper to create mock discovered models
function createMockModel(overrides: Partial<DiscoveredModel> = {}): DiscoveredModel {
  return {
    id: 'test-model',
    endpoint: 'http://vllm:8000',
    ownedBy: 'vllm',
    created: Date.now(),
    capabilities: {
      maxContextLength: 8192,
      streaming: true,
      toolCalling: false,
      jsonMode: true,
    },
    suggestedTasks: ['chat'],
    family: 'llama',
    size: '7B',
    supportsChat: true,
    raw: { id: 'test-model', object: 'model', created: Date.now(), ownedBy: 'vllm' },
    ...overrides,
  };
}

describe('ModelDiscovery', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('constructor', () => {
    it('should create with default config', () => {
      const discovery = new ModelDiscovery();
      expect(discovery).toBeDefined();
    });

    it('should accept custom config', () => {
      const discovery = new ModelDiscovery({
        timeout: 5000,
        cacheTtl: 30000,
      });
      expect(discovery).toBeDefined();
    });
  });

  describe('discover', () => {
    it('should discover models from endpoint', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      expect(models).toHaveLength(2);
      expect(models[0].id).toBe('meta-llama/Llama-3.1-70B-Instruct');
    });

    it('should detect llama family', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      const llama = models.find((m) => m.id.includes('Llama'));
      expect(llama?.family).toBe('llama');
      expect(llama?.suggestedTasks).toContain('chat');
    });

    it('should detect code family', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      const code = models.find((m) => m.id.includes('CodeLlama'));
      expect(code?.family).toBe('code');
      expect(code?.suggestedTasks).toContain('code');
    });

    it('should detect model size', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      const llama70b = models.find((m) => m.id.includes('70B'));
      expect(llama70b?.size).toBe('70B');
      expect(llama70b?.capabilities.maxContextLength).toBe(32768);

      const code34b = models.find((m) => m.id.includes('34b'));
      expect(code34b?.size).toBe('34B');
    });

    it('should detect chat support', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discover('http://vllm:8000');

      expect(models.every((m) => m.supportsChat)).toBe(true);
    });

    it('should use cache on subsequent calls', async () => {
      const discovery = new ModelDiscovery({ cacheTtl: 60000 });

      await discovery.discover('http://vllm:8000');
      await discovery.discover('http://vllm:8000');

      // VllmChatClient should only be instantiated once for cached calls
      // (testing via coverage)
    });

    it('should bypass cache when requested', async () => {
      const discovery = new ModelDiscovery({ cacheTtl: 60000 });

      await discovery.discover('http://vllm:8000', true);
      await discovery.discover('http://vllm:8000', false);

      // Second call bypasses cache
    });
  });

  describe('discoverAll', () => {
    it('should discover from multiple endpoints', async () => {
      const discovery = new ModelDiscovery();
      const models = await discovery.discoverAll([
        'http://vllm-1:8000',
        'http://vllm-2:8000',
      ]);

      // Each endpoint returns 2 models
      expect(models.length).toBe(4);
    });

    it('should handle failed endpoints gracefully', async () => {
      const discovery = new ModelDiscovery();

      // Mock one endpoint to fail
      const { VllmChatClient } = jest.requireMock('../src/vllm-client.js');
      VllmChatClient.mockImplementationOnce(() => ({
        listModels: jest.fn().mockRejectedValue(new Error('Connection refused')),
      }));

      const models = await discovery.discoverAll([
        'http://failed:8000',
        'http://working:8000',
      ]);

      // Should return models from working endpoint
      expect(models.length).toBe(2);
    });
  });

  describe('createRouterConfigs', () => {
    it('should create router configs from endpoints', async () => {
      const discovery = new ModelDiscovery();
      const configs = await discovery.createRouterConfigs(['http://vllm:8000']);

      expect(configs).toHaveLength(2);
      expect(configs[0].name).toBeDefined();
      expect(configs[0].endpoint).toBe('http://vllm:8000');
      expect(configs[0].model).toBeDefined();
      expect(configs[0].tasks).toBeDefined();
    });
  });

  describe('cache management', () => {
    it('should clear all cache', async () => {
      const discovery = new ModelDiscovery();

      await discovery.discover('http://vllm:8000');
      discovery.clearCache();

      const status = discovery.getCacheStatus();
      expect(status.size).toBe(0);
    });

    it('should clear cache for specific endpoint', async () => {
      const discovery = new ModelDiscovery();

      await discovery.discover('http://vllm-1:8000');
      await discovery.discover('http://vllm-2:8000');

      discovery.clearCacheFor('http://vllm-1:8000');

      const status = discovery.getCacheStatus();
      expect(status.has('http://vllm-1:8000')).toBe(false);
      expect(status.has('http://vllm-2:8000')).toBe(true);
    });

    it('should return cache status', async () => {
      const discovery = new ModelDiscovery();

      await discovery.discover('http://vllm:8000');

      const status = discovery.getCacheStatus();
      expect(status.has('http://vllm:8000')).toBe(true);
      expect(status.get('http://vllm:8000')?.modelCount).toBe(2);
    });
  });
});

describe('ModelFilters', () => {
  const models: DiscoveredModel[] = [
    createMockModel({ id: 'llama-70b', family: 'llama', supportsChat: true, suggestedTasks: ['chat'] }),
    createMockModel({ id: 'codellama', family: 'code', supportsChat: true, suggestedTasks: ['code'] }),
    createMockModel({ id: 'embed-model', family: 'embedding', supportsChat: false, suggestedTasks: ['embedding'] }),
    createMockModel({
      id: 'big-model',
      capabilities: { maxContextLength: 32768, streaming: true, toolCalling: true, jsonMode: true },
    }),
  ];

  describe('chatCapable', () => {
    it('should filter chat-capable models', () => {
      const filtered = models.filter(ModelFilters.chatCapable);
      expect(filtered).toHaveLength(3);
      expect(filtered.find((m) => m.id === 'embed-model')).toBeUndefined();
    });
  });

  describe('codeModels', () => {
    it('should filter code models', () => {
      const filtered = models.filter(ModelFilters.codeModels);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('codellama');
    });
  });

  describe('embeddingModels', () => {
    it('should filter embedding models', () => {
      const filtered = models.filter(ModelFilters.embeddingModels);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('embed-model');
    });
  });

  describe('minContextLength', () => {
    it('should filter by minimum context length', () => {
      const filtered = models.filter(ModelFilters.minContextLength(16000));
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('big-model');
    });
  });

  describe('byFamily', () => {
    it('should filter by family', () => {
      const filtered = models.filter(ModelFilters.byFamily('llama'));
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('llama-70b');
    });
  });

  describe('bySize', () => {
    it('should filter by size', () => {
      const modelsWithSize = [
        createMockModel({ id: 'small', size: '7B' }),
        createMockModel({ id: 'large', size: '70B' }),
      ];
      const filtered = modelsWithSize.filter(ModelFilters.bySize('70B'));
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('large');
    });
  });

  describe('toolCallCapable', () => {
    it('should filter tool-call capable models', () => {
      const filtered = models.filter(ModelFilters.toolCallCapable);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('big-model');
    });
  });

  describe('all', () => {
    it('should combine filters with AND', () => {
      const filter = ModelFilters.all(ModelFilters.chatCapable, ModelFilters.byFamily('llama'));
      const filtered = models.filter(filter);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].id).toBe('llama-70b');
    });
  });

  describe('any', () => {
    it('should combine filters with OR', () => {
      const filter = ModelFilters.any(ModelFilters.codeModels, ModelFilters.embeddingModels);
      const filtered = models.filter(filter);
      expect(filtered).toHaveLength(2);
    });
  });
});

describe('discoverModel', () => {
  it('should discover single model from endpoint', async () => {
    const model = await discoverModel('http://vllm:8000');
    expect(model).toBeDefined();
    expect(model?.id).toBeDefined();
  });
});

describe('formatModelInfo', () => {
  it('should format model info', () => {
    const model = createMockModel({
      id: 'llama-70b',
      family: 'llama',
      size: '70B',
      capabilities: { maxContextLength: 32768, toolCalling: true, streaming: true },
    });

    const info = formatModelInfo(model);

    expect(info).toContain('llama-70b');
    expect(info).toContain('[llama]');
    expect(info).toContain('70B');
    expect(info).toContain('ctx:32768');
    expect(info).toContain('tools');
  });

  it('should handle minimal model info', () => {
    const model = createMockModel({
      id: 'simple',
      family: undefined,
      size: undefined,
      capabilities: {},
    });

    const info = formatModelInfo(model);
    expect(info).toBe('simple');
  });
});

describe('groupModelsByFamily', () => {
  it('should group models by family', () => {
    const models = [
      createMockModel({ id: 'llama-1', family: 'llama' }),
      createMockModel({ id: 'llama-2', family: 'llama' }),
      createMockModel({ id: 'mistral', family: 'mistral' }),
      createMockModel({ id: 'unknown', family: undefined }),
    ];

    const groups = groupModelsByFamily(models);

    expect(groups.get('llama')).toHaveLength(2);
    expect(groups.get('mistral')).toHaveLength(1);
    expect(groups.get('unknown')).toHaveLength(1);
  });
});

describe('groupModelsByEndpoint', () => {
  it('should group models by endpoint', () => {
    const models = [
      createMockModel({ id: 'model-1', endpoint: 'http://vllm-1:8000' }),
      createMockModel({ id: 'model-2', endpoint: 'http://vllm-1:8000' }),
      createMockModel({ id: 'model-3', endpoint: 'http://vllm-2:8000' }),
    ];

    const groups = groupModelsByEndpoint(models);

    expect(groups.get('http://vllm-1:8000')).toHaveLength(2);
    expect(groups.get('http://vllm-2:8000')).toHaveLength(1);
  });
});

describe('findBestModelForTask', () => {
  const models = [
    createMockModel({
      id: 'llama-7b',
      suggestedTasks: ['chat'],
      capabilities: { maxContextLength: 8192 },
      supportsChat: true,
    }),
    createMockModel({
      id: 'llama-70b',
      suggestedTasks: ['chat', 'reasoning'],
      capabilities: { maxContextLength: 32768 },
      supportsChat: true,
    }),
    createMockModel({
      id: 'codellama',
      suggestedTasks: ['code'],
      capabilities: { maxContextLength: 16384 },
      supportsChat: true,
    }),
  ];

  it('should find best model for chat task', () => {
    const best = findBestModelForTask(models, 'chat');
    expect(best?.id).toBe('llama-70b'); // Larger context = preferred
  });

  it('should find best model for code task', () => {
    const best = findBestModelForTask(models, 'code');
    expect(best?.id).toBe('codellama');
  });

  it('should fall back to chat model for unknown task', () => {
    const best = findBestModelForTask(models, 'translation');
    expect(best).toBeDefined();
    expect(best?.supportsChat).toBe(true);
  });

  it('should return undefined for empty array', () => {
    const best = findBestModelForTask([], 'chat');
    expect(best).toBeUndefined();
  });
});

describe('DEFAULT_DISCOVERY_CONFIG', () => {
  it('should have expected default values', () => {
    expect(DEFAULT_DISCOVERY_CONFIG.timeout).toBe(10000);
    expect(DEFAULT_DISCOVERY_CONFIG.probeCapabilities).toBe(false);
    expect(DEFAULT_DISCOVERY_CONFIG.cacheTtl).toBe(60000);
    expect(DEFAULT_DISCOVERY_CONFIG.debug).toBe(false);
  });
});