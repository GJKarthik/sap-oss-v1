/**
 * Jest test setup for @sap-ai-sdk/elasticsearch
 */

// Increase timeout for integration tests
jest.setTimeout(30000);

// Mock console during tests to reduce noise
const originalConsoleError = console.error;
const originalConsoleWarn = console.warn;

beforeAll(() => {
  // Suppress expected error messages during tests
  console.error = (...args: unknown[]) => {
    const message = args[0];
    if (
      typeof message === 'string' &&
      (message.includes('Expected error') ||
        message.includes('Test error') ||
        message.includes('ECONNREFUSED'))
    ) {
      return;
    }
    originalConsoleError.apply(console, args);
  };

  console.warn = (...args: unknown[]) => {
    const message = args[0];
    if (
      typeof message === 'string' &&
      message.includes('Test warning')
    ) {
      return;
    }
    originalConsoleWarn.apply(console, args);
  };
});

afterAll(() => {
  console.error = originalConsoleError;
  console.warn = originalConsoleWarn;
});

// Clean up after each test
afterEach(() => {
  jest.clearAllMocks();
});

// Global test utilities
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace jest {
    interface Matchers<R> {
      toBeValidEmbedding(dims?: number): R;
    }
  }
}

// Custom matcher for embedding validation
expect.extend({
  toBeValidEmbedding(received: unknown, dims?: number) {
    if (!Array.isArray(received)) {
      return {
        message: () => `expected ${received} to be an array`,
        pass: false,
      };
    }

    const allNumbers = received.every(
      (v) => typeof v === 'number' && !isNaN(v)
    );
    if (!allNumbers) {
      return {
        message: () => `expected all elements to be valid numbers`,
        pass: false,
      };
    }

    if (dims !== undefined && received.length !== dims) {
      return {
        message: () =>
          `expected embedding to have ${dims} dimensions, got ${received.length}`,
        pass: false,
      };
    }

    return {
      message: () => `expected ${received} not to be a valid embedding`,
      pass: true,
    };
  },
});

// Export test utilities
export const createMockEmbedding = (dims: number = 1536): number[] => {
  return Array.from({ length: dims }, () => Math.random() * 2 - 1);
};

export const createMockDocument = (
  id: string,
  content: string,
  embedding?: number[]
) => ({
  id,
  content,
  embedding: embedding ?? createMockEmbedding(),
  metadata: {
    source: 'test',
    createdAt: new Date().toISOString(),
  },
});

export const createMockSearchResult = (
  id: string,
  score: number,
  content: string
) => ({
  id,
  score,
  content,
  metadata: { source: 'test' },
});

export const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

// Mock Elasticsearch client factory
export const createMockEsClient = () => ({
  indices: {
    exists: jest.fn().mockResolvedValue(true),
    create: jest.fn().mockResolvedValue({ acknowledged: true }),
    delete: jest.fn().mockResolvedValue({ acknowledged: true }),
    stats: jest.fn().mockResolvedValue({
      _all: {
        primaries: {
          docs: { count: 100 },
          store: { size_in_bytes: 1000000 },
        },
      },
      indices: {
        'test-index': {
          health: 'green',
          primaries: { docs: { count: 100 } },
          settings: {
            index: { number_of_shards: '1', number_of_replicas: '1' },
          },
        },
      },
    }),
  },
  index: jest.fn().mockResolvedValue({
    _id: 'doc-1',
    result: 'created',
  }),
  bulk: jest.fn().mockResolvedValue({
    took: 100,
    errors: false,
    items: [],
  }),
  delete: jest.fn().mockResolvedValue({
    result: 'deleted',
  }),
  get: jest.fn().mockResolvedValue({
    _id: 'doc-1',
    _source: {
      content: 'Test content',
      embedding: createMockEmbedding(),
      metadata: {},
    },
    found: true,
  }),
  search: jest.fn().mockResolvedValue({
    took: 10,
    hits: {
      total: { value: 1, relation: 'eq' },
      max_score: 0.9,
      hits: [
        {
          _id: 'doc-1',
          _score: 0.9,
          _source: {
            content: 'Test content',
            embedding: createMockEmbedding(),
            metadata: {},
          },
        },
      ],
    },
  }),
  info: jest.fn().mockResolvedValue({
    version: { number: '8.12.0' },
    cluster_name: 'test-cluster',
  }),
  close: jest.fn().mockResolvedValue(undefined),
});