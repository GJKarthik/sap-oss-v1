/**
 * Tests for client factory and configuration builder
 */

import {
  buildIndexMapping,
  ElasticsearchConfigBuilder,
  configBuilder,
  ConfigPresets,
} from '../src/client-factory';
import { ElasticsearchConfigError } from '../src/errors';
import type { ElasticsearchConfig } from '../src/types';

describe('buildIndexMapping', () => {
  it('should build default mapping', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
    });

    expect(mapping).toHaveProperty('mappings');
    expect(mapping).toHaveProperty('settings');

    const props = (mapping.mappings as Record<string, unknown>).properties as Record<string, unknown>;
    expect(props).toHaveProperty('content');
    expect(props).toHaveProperty('embedding');
    expect(props).toHaveProperty('metadata');
    expect(props).toHaveProperty('indexed_at');
  });

  it('should set embedding dimensions', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 768,
    });

    const props = (mapping.mappings as Record<string, unknown>).properties as Record<string, unknown>;
    const embedding = props.embedding as Record<string, unknown>;
    expect(embedding.dims).toBe(768);
  });

  it('should use custom field names', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
      embeddingField: 'vector',
      contentField: 'text',
      metadataField: 'meta',
    });

    const props = (mapping.mappings as Record<string, unknown>).properties as Record<string, unknown>;
    expect(props).toHaveProperty('vector');
    expect(props).toHaveProperty('text');
    expect(props).toHaveProperty('meta');
    expect(props).not.toHaveProperty('embedding');
    expect(props).not.toHaveProperty('content');
    expect(props).not.toHaveProperty('metadata');
  });

  it('should set similarity metric', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
      similarity: 'dot_product',
    });

    const props = (mapping.mappings as Record<string, unknown>).properties as Record<string, unknown>;
    const embedding = props.embedding as Record<string, unknown>;
    expect(embedding.similarity).toBe('dot_product');
  });

  it('should set index settings', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
      settings: {
        numberOfShards: 3,
        numberOfReplicas: 2,
        refreshInterval: '5s',
        maxResultWindow: 50000,
      },
    });

    const settings = mapping.settings as Record<string, unknown>;
    expect(settings.number_of_shards).toBe(3);
    expect(settings.number_of_replicas).toBe(2);
    expect(settings.refresh_interval).toBe('5s');
    expect(settings.max_result_window).toBe(50000);
  });

  it('should set HNSW parameters', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
      settings: {
        knn: {
          algoParam: {
            m: 32,
            efConstruction: 200,
          },
        },
      },
    });

    const props = (mapping.mappings as Record<string, unknown>).properties as Record<string, unknown>;
    const embedding = props.embedding as Record<string, unknown>;
    const indexOptions = embedding.index_options as Record<string, unknown>;
    expect(indexOptions.type).toBe('hnsw');
    expect(indexOptions.m).toBe(32);
    expect(indexOptions.ef_construction).toBe(200);
  });

  it('should set custom analyzers', () => {
    const mapping = buildIndexMapping({
      embeddingDims: 1536,
      settings: {
        analyzers: {
          custom_analyzer: {
            type: 'custom',
            tokenizer: 'standard',
            filter: ['lowercase', 'stemmer'],
          },
        },
      },
    });

    const settings = mapping.settings as Record<string, unknown>;
    const analysis = settings.analysis as Record<string, unknown>;
    const analyzers = analysis.analyzer as Record<string, unknown>;
    expect(analyzers).toHaveProperty('custom_analyzer');
  });
});

describe('ElasticsearchConfigBuilder', () => {
  describe('node configuration', () => {
    it('should set single node', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.node).toBe('https://localhost:9200');
    });

    it('should set multiple nodes', () => {
      const config = configBuilder()
        .node(['https://node1:9200', 'https://node2:9200'])
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.node).toEqual(['https://node1:9200', 'https://node2:9200']);
    });
  });

  describe('cloud configuration', () => {
    it('should set cloud ID', () => {
      const config = configBuilder()
        .cloud('my-deployment:base64id')
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.cloud).toEqual({ id: 'my-deployment:base64id' });
    });
  });

  describe('authentication', () => {
    it('should set API key', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .apiKey('my-api-key')
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.auth).toEqual({ apiKey: 'my-api-key' });
    });

    it('should set basic auth', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .basicAuth('user', 'pass')
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.auth).toEqual({ username: 'user', password: 'pass' });
    });

    it('should set bearer token', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .bearerToken('my-token')
        .index('test-index')
        .embeddingDimensions(1536)
        .build();

      expect(config.auth).toEqual({ bearer: 'my-token' });
    });
  });

  describe('index configuration', () => {
    it('should set index name', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('my-vectors')
        .embeddingDimensions(1536)
        .build();

      expect(config.indexName).toBe('my-vectors');
    });

    it('should set embedding dimensions', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(768)
        .build();

      expect(config.embeddingDims).toBe(768);
    });

    it('should set similarity metric', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .similarity('dot_product')
        .build();

      expect(config.similarity).toBe('dot_product');
    });
  });

  describe('field names', () => {
    it('should set custom field names', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .embeddingField('vector')
        .contentField('text')
        .metadataField('meta')
        .build();

      expect(config.embeddingField).toBe('vector');
      expect(config.contentField).toBe('text');
      expect(config.metadataField).toBe('meta');
    });
  });

  describe('connection options', () => {
    it('should set max retries', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .maxRetries(5)
        .build();

      expect(config.maxRetries).toBe(5);
    });

    it('should set timeout', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .timeout(60000)
        .build();

      expect(config.requestTimeout).toBe(60000);
    });

    it('should enable compression', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .compression()
        .build();

      expect(config.compression).toBe(true);
    });

    it('should set TLS options', () => {
      const config = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536)
        .tls({ rejectUnauthorized: false })
        .build();

      expect(config.tls).toEqual({ rejectUnauthorized: false });
    });
  });

  describe('validation', () => {
    it('should throw if node and cloud are missing', () => {
      expect(() =>
        configBuilder()
          .index('test')
          .embeddingDimensions(1536)
          .build()
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw if index name is missing', () => {
      expect(() =>
        configBuilder()
          .node('https://localhost:9200')
          .embeddingDimensions(1536)
          .build()
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw if embedding dimensions are missing', () => {
      expect(() =>
        configBuilder()
          .node('https://localhost:9200')
          .index('test')
          .build()
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('clone', () => {
    it('should create independent copy', () => {
      const builder1 = configBuilder()
        .node('https://localhost:9200')
        .index('test')
        .embeddingDimensions(1536);

      const builder2 = builder1.clone().index('other-test');

      const config1 = builder1.build();
      const config2 = builder2.build();

      expect(config1.indexName).toBe('test');
      expect(config2.indexName).toBe('other-test');
    });
  });
});

describe('ConfigPresets', () => {
  describe('local', () => {
    it('should create local config', () => {
      const config = ConfigPresets.local('test-index');

      expect(config.node).toBe('http://localhost:9200');
      expect(config.indexName).toBe('test-index');
      expect(config.embeddingDims).toBe(1536);
    });

    it('should accept custom dimensions', () => {
      const config = ConfigPresets.local('test-index', 768);

      expect(config.embeddingDims).toBe(768);
    });
  });

  describe('elasticCloud', () => {
    it('should create cloud config', () => {
      const config = ConfigPresets.elasticCloud(
        'cloud-id',
        'api-key',
        'test-index'
      );

      expect(config.cloud).toEqual({ id: 'cloud-id' });
      expect(config.auth).toEqual({ apiKey: 'api-key' });
      expect(config.compression).toBe(true);
    });
  });

  describe('openAI', () => {
    it('should create OpenAI preset', () => {
      const config = ConfigPresets.openAI(
        'https://localhost:9200',
        'test-index'
      );

      expect(config.embeddingDims).toBe(1536);
      expect(config.similarity).toBe('cosine');
    });
  });

  describe('cohere', () => {
    it('should create Cohere preset', () => {
      const config = ConfigPresets.cohere(
        'https://localhost:9200',
        'test-index'
      );

      expect(config.embeddingDims).toBe(1024);
      expect(config.similarity).toBe('cosine');
    });
  });

  describe('production', () => {
    it('should create production config', () => {
      const config = ConfigPresets.production(
        ['https://node1:9200', 'https://node2:9200'],
        'test-index',
        1536,
        'api-key'
      );

      expect(config.compression).toBe(true);
      expect(config.maxRetries).toBe(5);
      expect(config.requestTimeout).toBe(60000);
    });
  });
});