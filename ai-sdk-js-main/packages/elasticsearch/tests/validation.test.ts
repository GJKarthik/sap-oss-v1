/**
 * Tests for configuration validation utilities
 */

import {
  validateConfig,
  validateDocument,
  validateDocuments,
  validateEmbedding,
  validateRetrieveOptions,
  validateHybridSearchOptions,
  validateIndexSettings,
  normalizeEmbedding,
  isNormalizedEmbedding,
  generateDocumentId,
  sanitizeIndexName,
} from '../src/validation';
import {
  ElasticsearchConfigError,
  ElasticsearchValidationError,
  ElasticsearchEmbeddingError,
} from '../src/errors';
import type { ElasticsearchConfig, Document } from '../src/types';

describe('validateConfig', () => {
  const validConfig: ElasticsearchConfig = {
    node: 'https://localhost:9200',
    indexName: 'test-index',
    embeddingDims: 1536,
  };

  describe('required fields', () => {
    it('should pass with valid config', () => {
      expect(() => validateConfig(validConfig)).not.toThrow();
    });

    it('should throw if node and cloud are missing', () => {
      expect(() =>
        validateConfig({
          indexName: 'test',
          embeddingDims: 1536,
        } as ElasticsearchConfig)
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw if indexName is missing', () => {
      expect(() =>
        validateConfig({
          node: 'https://localhost:9200',
          embeddingDims: 1536,
        } as ElasticsearchConfig)
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw if embeddingDims is missing', () => {
      expect(() =>
        validateConfig({
          node: 'https://localhost:9200',
          indexName: 'test',
        } as ElasticsearchConfig)
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw if embeddingDims is not positive', () => {
      expect(() =>
        validateConfig({
          ...validConfig,
          embeddingDims: 0,
        })
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('node validation', () => {
    it('should accept valid HTTP URL', () => {
      expect(() =>
        validateConfig({ ...validConfig, node: 'http://localhost:9200' })
      ).not.toThrow();
    });

    it('should accept valid HTTPS URL', () => {
      expect(() =>
        validateConfig({ ...validConfig, node: 'https://elastic.example.com:9243' })
      ).not.toThrow();
    });

    it('should accept array of nodes', () => {
      expect(() =>
        validateConfig({
          ...validConfig,
          node: ['https://node1:9200', 'https://node2:9200'],
        })
      ).not.toThrow();
    });

    it('should throw for invalid URL', () => {
      expect(() =>
        validateConfig({ ...validConfig, node: 'not-a-url' })
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw for non-HTTP protocol', () => {
      expect(() =>
        validateConfig({ ...validConfig, node: 'ftp://localhost:9200' })
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('cloud validation', () => {
    it('should accept valid cloud config', () => {
      expect(() =>
        validateConfig({
          indexName: 'test',
          embeddingDims: 1536,
          cloud: { id: 'my-deployment:dXMtZWFzdC0xLmF3cy5mb3VuZC5pbw==' },
        })
      ).not.toThrow();
    });

    it('should throw if cloud.id is missing', () => {
      expect(() =>
        validateConfig({
          indexName: 'test',
          embeddingDims: 1536,
          cloud: {} as { id: string },
        })
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('index name validation', () => {
    it('should accept valid index names', () => {
      expect(() =>
        validateConfig({ ...validConfig, indexName: 'my-index' })
      ).not.toThrow();
      expect(() =>
        validateConfig({ ...validConfig, indexName: 'documents2024' })
      ).not.toThrow();
    });

    it('should throw for uppercase index name', () => {
      expect(() =>
        validateConfig({ ...validConfig, indexName: 'MyIndex' })
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw for index name starting with -', () => {
      expect(() =>
        validateConfig({ ...validConfig, indexName: '-index' })
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw for index name with special characters', () => {
      expect(() =>
        validateConfig({ ...validConfig, indexName: 'my*index' })
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('similarity validation', () => {
    it('should accept valid similarity metrics', () => {
      expect(() =>
        validateConfig({ ...validConfig, similarity: 'cosine' })
      ).not.toThrow();
      expect(() =>
        validateConfig({ ...validConfig, similarity: 'dot_product' })
      ).not.toThrow();
      expect(() =>
        validateConfig({ ...validConfig, similarity: 'l2_norm' })
      ).not.toThrow();
    });

    it('should throw for invalid similarity', () => {
      expect(() =>
        validateConfig({ ...validConfig, similarity: 'invalid' as 'cosine' })
      ).toThrow(ElasticsearchConfigError);
    });
  });

  describe('optional fields', () => {
    it('should throw for negative maxRetries', () => {
      expect(() =>
        validateConfig({ ...validConfig, maxRetries: -1 })
      ).toThrow(ElasticsearchConfigError);
    });

    it('should throw for negative requestTimeout', () => {
      expect(() =>
        validateConfig({ ...validConfig, requestTimeout: -1 })
      ).toThrow(ElasticsearchConfigError);
    });
  });
});

describe('validateDocument', () => {
  const embeddingDims = 3;

  it('should pass with valid document', () => {
    expect(() =>
      validateDocument(
        { content: 'Test content', embedding: [0.1, 0.2, 0.3] },
        embeddingDims
      )
    ).not.toThrow();
  });

  it('should pass without embedding if not required', () => {
    expect(() =>
      validateDocument({ content: 'Test content' }, embeddingDims, false)
    ).not.toThrow();
  });

  it('should throw if embedding required but missing', () => {
    expect(() =>
      validateDocument({ content: 'Test content' }, embeddingDims, true)
    ).toThrow(ElasticsearchEmbeddingError);
  });

  it('should throw for empty content', () => {
    expect(() =>
      validateDocument({ content: '' }, embeddingDims)
    ).toThrow(ElasticsearchValidationError);
  });

  it('should throw for non-string content', () => {
    expect(() =>
      validateDocument({ content: 123 as unknown as string }, embeddingDims)
    ).toThrow(ElasticsearchValidationError);
  });

  it('should throw for non-string id', () => {
    expect(() =>
      validateDocument(
        { content: 'Test', id: 123 as unknown as string },
        embeddingDims
      )
    ).toThrow(ElasticsearchValidationError);
  });
});

describe('validateEmbedding', () => {
  const dims = 4;

  it('should pass with valid embedding', () => {
    expect(() => validateEmbedding([0.1, 0.2, 0.3, 0.4], dims)).not.toThrow();
  });

  it('should throw if not an array', () => {
    expect(() => validateEmbedding('not an array', dims)).toThrow(
      ElasticsearchEmbeddingError
    );
  });

  it('should throw for wrong dimensions', () => {
    expect(() => validateEmbedding([0.1, 0.2], dims)).toThrow(
      ElasticsearchEmbeddingError
    );
  });

  it('should throw for NaN values', () => {
    expect(() => validateEmbedding([0.1, NaN, 0.3, 0.4], dims)).toThrow(
      ElasticsearchEmbeddingError
    );
  });

  it('should throw for infinite values', () => {
    expect(() => validateEmbedding([0.1, Infinity, 0.3, 0.4], dims)).toThrow(
      ElasticsearchEmbeddingError
    );
  });

  it('should throw for non-number values', () => {
    expect(() =>
      validateEmbedding([0.1, 'string' as unknown as number, 0.3, 0.4], dims)
    ).toThrow(ElasticsearchEmbeddingError);
  });
});

describe('validateDocuments', () => {
  it('should pass with valid documents', () => {
    expect(() =>
      validateDocuments(
        [
          { content: 'Doc 1', embedding: [0.1, 0.2] },
          { content: 'Doc 2', embedding: [0.3, 0.4] },
        ],
        2
      )
    ).not.toThrow();
  });

  it('should throw for empty array', () => {
    expect(() => validateDocuments([], 2)).toThrow(
      ElasticsearchValidationError
    );
  });

  it('should throw for non-array', () => {
    expect(() =>
      validateDocuments('not an array' as unknown as Document[], 2)
    ).toThrow(ElasticsearchValidationError);
  });

  it('should include index in error message', () => {
    expect(() =>
      validateDocuments(
        [{ content: 'Valid' }, { content: '' }],
        2
      )
    ).toThrow(/index 1/);
  });
});

describe('validateRetrieveOptions', () => {
  it('should pass with valid options', () => {
    expect(() => validateRetrieveOptions({ k: 10 })).not.toThrow();
  });

  it('should pass with empty options', () => {
    expect(() => validateRetrieveOptions({})).not.toThrow();
  });

  it('should throw for non-positive k', () => {
    expect(() => validateRetrieveOptions({ k: 0 })).toThrow(
      ElasticsearchValidationError
    );
  });

  it('should throw for k > 10000', () => {
    expect(() => validateRetrieveOptions({ k: 10001 })).toThrow(
      ElasticsearchValidationError
    );
  });

  it('should throw for numCandidates < k', () => {
    expect(() =>
      validateRetrieveOptions({ k: 10, numCandidates: 5 })
    ).toThrow(ElasticsearchValidationError);
  });
});

describe('validateHybridSearchOptions', () => {
  it('should pass with valid options', () => {
    expect(() =>
      validateHybridSearchOptions({
        k: 10,
        vectorWeight: 0.7,
        textWeight: 0.3,
      })
    ).not.toThrow();
  });

  it('should throw for vectorWeight > 1', () => {
    expect(() =>
      validateHybridSearchOptions({ vectorWeight: 1.5 })
    ).toThrow(ElasticsearchValidationError);
  });

  it('should throw for textWeight < 0', () => {
    expect(() =>
      validateHybridSearchOptions({ textWeight: -0.1 })
    ).toThrow(ElasticsearchValidationError);
  });

  it('should throw for non-array textFields', () => {
    expect(() =>
      validateHybridSearchOptions({
        textFields: 'content' as unknown as string[],
      })
    ).toThrow(ElasticsearchValidationError);
  });
});

describe('validateIndexSettings', () => {
  it('should pass with valid settings', () => {
    expect(() =>
      validateIndexSettings({
        numberOfShards: 2,
        numberOfReplicas: 1,
      })
    ).not.toThrow();
  });

  it('should throw for non-positive numberOfShards', () => {
    expect(() => validateIndexSettings({ numberOfShards: 0 })).toThrow(
      ElasticsearchValidationError
    );
  });

  it('should throw for negative numberOfReplicas', () => {
    expect(() => validateIndexSettings({ numberOfReplicas: -1 })).toThrow(
      ElasticsearchValidationError
    );
  });

  it('should throw for invalid knn.algoParam.m', () => {
    expect(() =>
      validateIndexSettings({ knn: { algoParam: { m: 1 } } })
    ).toThrow(ElasticsearchValidationError);
  });
});

describe('normalizeEmbedding', () => {
  it('should normalize embedding to unit length', () => {
    const embedding = [3, 4]; // 3-4-5 triangle
    const normalized = normalizeEmbedding(embedding);
    expect(normalized[0]).toBeCloseTo(0.6);
    expect(normalized[1]).toBeCloseTo(0.8);
  });

  it('should handle zero vector', () => {
    const embedding = [0, 0, 0];
    const normalized = normalizeEmbedding(embedding);
    expect(normalized).toEqual([0, 0, 0]);
  });
});

describe('isNormalizedEmbedding', () => {
  it('should return true for normalized embedding', () => {
    expect(isNormalizedEmbedding([0.6, 0.8])).toBe(true);
  });

  it('should return false for non-normalized embedding', () => {
    expect(isNormalizedEmbedding([3, 4])).toBe(false);
  });
});

describe('generateDocumentId', () => {
  it('should generate unique IDs', () => {
    const ids = new Set<string>();
    for (let i = 0; i < 100; i++) {
      ids.add(generateDocumentId());
    }
    expect(ids.size).toBe(100);
  });

  it('should generate valid string IDs', () => {
    const id = generateDocumentId();
    expect(typeof id).toBe('string');
    expect(id.length).toBeGreaterThan(0);
  });
});

describe('sanitizeIndexName', () => {
  it('should convert to lowercase', () => {
    expect(sanitizeIndexName('MyIndex')).toBe('myindex');
  });

  it('should remove leading special characters', () => {
    expect(sanitizeIndexName('-_+index')).toBe('index');
  });

  it('should replace special characters with dashes', () => {
    expect(sanitizeIndexName('my*index?name')).toBe('my-index-name');
  });
});