/**
 * Unit tests for MangleClient (mock-based, no real gRPC server needed).
 */

import { MangleClient } from './mangle-client';

// These tests use a mock approach - they verify the client interface
// without requiring a running gRPC server.

describe('MangleClient', () => {
  test('creates client with default config', () => {
    // Note: This will fail if @grpc/grpc-js is not installed.
    // In that case, skip this test with: SKIP_GRPC_TESTS=1
    if (process.env.SKIP_GRPC_TESTS) {
      return;
    }
    const client = new MangleClient({ address: 'localhost:50051' });
    expect(client).toBeDefined();
    client.close();
  });

  test('resolve returns structured response (mocked)', async () => {
    if (process.env.SKIP_GRPC_TESTS) {
      return;
    }
    const client = new MangleClient({ address: 'localhost:50051' });

    // Override internal client with mock
    (client as any)._client = {
      Resolve: (_req: any, _opts: any, cb: Function) =>
        cb(null, {
          answer: 'test answer',
          path: 'cache',
          confidence: 0.97,
          sources: [],
          latencyMs: 12,
          correlationId: 'test-123',
        }),
      close: () => {},
    };

    const result = await client.resolve('test query', [], 'test-123');
    expect(result.path).toBe('cache');
    expect(result.answer).toBe('test answer');
    expect(result.correlationId).toBe('test-123');
    client.close();
  });

  test('health returns status (mocked)', async () => {
    if (process.env.SKIP_GRPC_TESTS) {
      return;
    }
    const client = new MangleClient({ address: 'localhost:50051' });

    (client as any)._client = {
      Health: (_req: any, _opts: any, cb: Function) =>
        cb(null, {
          status: 'healthy',
          components: { mangle_engine: 'healthy' },
          metrics: {},
        }),
      close: () => {},
    };

    const result = await client.health();
    expect(result.status).toBe('healthy');
    client.close();
  });

  test('syncEntity returns success (mocked)', async () => {
    if (process.env.SKIP_GRPC_TESTS) {
      return;
    }
    const client = new MangleClient({ address: 'localhost:50051' });

    (client as any)._client = {
      SyncEntity: (_req: any, _opts: any, cb: Function) =>
        cb(null, { success: true, error: '' }),
      close: () => {},
    };

    const result = await client.syncEntity('orders', 'PO-123', 'update', '{"status":"delivered"}');
    expect(result.success).toBe(true);
    client.close();
  });
});
