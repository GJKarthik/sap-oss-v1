// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * HealthMonitor tests.
 */

import {
  HealthMonitor,
  type HealthMonitorConfig,
  type ModelHealthInfo,
  type HealthCheckCallback,
  type HealthStatusChangeCallback,
  createHealthMonitorForRouter,
  checkHealth,
  DEFAULT_HEALTH_MONITOR_CONFIG,
} from '../src/health-monitor.js';
import { ModelRouter, type RouterModelConfig } from '../src/model-router.js';

// Mock VllmChatClient
const createMockClient = (healthy = true) => ({
  healthCheck: jest.fn().mockResolvedValue({
    healthy,
    status: healthy ? 'ok' : 'error',
    timestamp: Date.now(),
  }),
  listModels: jest.fn().mockResolvedValue([
    { id: 'test-model', object: 'model', created: Date.now(), owned_by: 'vllm' },
  ]),
  chat: jest.fn().mockResolvedValue({
    id: 'test-response',
    model: 'test-model',
    choices: [{ message: { role: 'assistant', content: 'pong' } }],
  }),
});

// Mock ModelRouter
jest.mock('../src/model-router.js', () => {
  const actual = jest.requireActual('../src/model-router.js');
  return {
    ...actual,
    ModelRouter: jest.fn().mockImplementation(() => ({
      listModels: jest.fn().mockReturnValue(['model-1', 'model-2']),
      getClientByName: jest.fn().mockImplementation(() => createMockClient()),
      setModelStatus: jest.fn(),
    })),
  };
});

describe('HealthMonitor', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('constructor', () => {
    it('should create monitor with default config', () => {
      const monitor = new HealthMonitor();

      expect(monitor.isRunning).toBe(false);
      expect(monitor.clientCount).toBe(0);
    });

    it('should accept custom config', () => {
      const monitor = new HealthMonitor({
        interval: 5000,
        failureThreshold: 5,
      });

      expect(monitor.isRunning).toBe(false);
    });

    it('should auto-start if configured', () => {
      const monitor = new HealthMonitor({
        autoStart: true,
      });

      expect(monitor.isRunning).toBe(true);
      monitor.stop();
    });
  });

  describe('addClient/removeClient', () => {
    it('should add client', () => {
      const monitor = new HealthMonitor();
      const client = createMockClient();

      monitor.addClient('test', client as any);

      expect(monitor.clientCount).toBe(1);
      expect(monitor.getHealth('test')).toBeDefined();
    });

    it('should remove client', () => {
      const monitor = new HealthMonitor();
      const client = createMockClient();

      monitor.addClient('test', client as any);
      const removed = monitor.removeClient('test');

      expect(removed).toBe(true);
      expect(monitor.clientCount).toBe(0);
      expect(monitor.getHealth('test')).toBeUndefined();
    });

    it('should return false when removing non-existent client', () => {
      const monitor = new HealthMonitor();

      const removed = monitor.removeClient('nonexistent');

      expect(removed).toBe(false);
    });
  });

  describe('start/stop', () => {
    it('should start monitoring', () => {
      const monitor = new HealthMonitor();
      monitor.addClient('test', createMockClient() as any);

      monitor.start();

      expect(monitor.isRunning).toBe(true);
      monitor.stop();
    });

    it('should stop monitoring', () => {
      const monitor = new HealthMonitor();
      monitor.start();
      monitor.stop();

      expect(monitor.isRunning).toBe(false);
    });

    it('should not start twice', () => {
      const monitor = new HealthMonitor();

      monitor.start();
      monitor.start();

      expect(monitor.isRunning).toBe(true);
      monitor.stop();
    });

    it('should not throw when stopping non-running monitor', () => {
      const monitor = new HealthMonitor();

      expect(() => monitor.stop()).not.toThrow();
    });
  });

  describe('health checks', () => {
    it('should check health of all clients', async () => {
      const monitor = new HealthMonitor();
      const client1 = createMockClient(true);
      const client2 = createMockClient(false);

      monitor.addClient('healthy', client1 as any);
      monitor.addClient('unhealthy', client2 as any);

      await monitor.checkAll();

      expect(client1.healthCheck).toHaveBeenCalled();
      expect(client2.healthCheck).toHaveBeenCalled();
    });

    it('should check specific client', async () => {
      const monitor = new HealthMonitor();
      const client = createMockClient(true);

      monitor.addClient('test', client as any);

      const info = await monitor.check('test');

      expect(client.healthCheck).toHaveBeenCalled();
      expect(info?.healthy).toBe(true);
    });

    it('should return undefined for non-existent client', async () => {
      const monitor = new HealthMonitor();

      const info = await monitor.check('nonexistent');

      expect(info).toBeUndefined();
    });

    it('should track consecutive failures', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 2,
      });
      const client = createMockClient(false);

      monitor.addClient('test', client as any);

      // First failure - still healthy (below threshold)
      await monitor.check('test');
      let info = monitor.getHealth('test');
      expect(info?.consecutiveFailures).toBe(1);
      expect(info?.healthy).toBe(true);

      // Second failure - now unhealthy
      await monitor.check('test');
      info = monitor.getHealth('test');
      expect(info?.consecutiveFailures).toBe(2);
      expect(info?.healthy).toBe(false);
    });

    it('should reset failures on success', async () => {
      const monitor = new HealthMonitor();
      const client = createMockClient(true);

      monitor.addClient('test', client as any);

      // Simulate previous failures
      const info = monitor.getHealth('test')!;
      (info as any).consecutiveFailures = 5;
      (info as any).healthy = false;

      await monitor.check('test');

      expect(info.consecutiveFailures).toBe(0);
      expect(info.consecutiveSuccesses).toBe(1);
    });
  });

  describe('callbacks', () => {
    it('should call health check callback', async () => {
      const monitor = new HealthMonitor();
      const client = createMockClient(true);
      const callback = jest.fn();

      monitor.addClient('test', client as any);
      monitor.onHealthCheck(callback);

      await monitor.check('test');

      expect(callback).toHaveBeenCalledWith(
        'test',
        true,
        expect.objectContaining({ name: 'test', healthy: true }),
        undefined
      );
    });

    it('should call change callback on status change', async () => {
      const monitor = new HealthMonitor({
        failureThreshold: 1,
      });
      const client = createMockClient(false);
      const callback = jest.fn();

      monitor.addClient('test', client as any);
      monitor.onHealthChange(callback);

      await monitor.check('test');

      expect(callback).toHaveBeenCalledWith(
        'test',
        true, // previous
        false, // new
        expect.objectContaining({ name: 'test', healthy: false })
      );
    });

    it('should not call change callback when status unchanged', async () => {
      const monitor = new HealthMonitor();
      const client = createMockClient(true);
      const callback = jest.fn();

      monitor.addClient('test', client as any);
      monitor.onHealthChange(callback);

      await monitor.check('test');
      await monitor.check('test');

      expect(callback).not.toHaveBeenCalled();
    });
  });

  describe('getHealth', () => {
    it('should return health info for client', () => {
      const monitor = new HealthMonitor();
      monitor.addClient('test', createMockClient() as any);

      const info = monitor.getHealth('test');

      expect(info).toBeDefined();
      expect(info?.name).toBe('test');
    });

    it('should return undefined for unknown client', () => {
      const monitor = new HealthMonitor();

      const info = monitor.getHealth('unknown');

      expect(info).toBeUndefined();
    });
  });

  describe('getAllHealth', () => {
    it('should return all health info', () => {
      const monitor = new HealthMonitor();
      monitor.addClient('client1', createMockClient() as any);
      monitor.addClient('client2', createMockClient() as any);

      const health = monitor.getAllHealth();

      expect(health.size).toBe(2);
      expect(health.has('client1')).toBe(true);
      expect(health.has('client2')).toBe(true);
    });
  });

  describe('getAggregateHealth', () => {
    it('should return aggregate health stats', async () => {
      const monitor = new HealthMonitor({ failureThreshold: 1 });
      monitor.addClient('healthy1', createMockClient(true) as any);
      monitor.addClient('healthy2', createMockClient(true) as any);
      monitor.addClient('unhealthy', createMockClient(false) as any);

      await monitor.checkAll();

      const aggregate = monitor.getAggregateHealth();

      expect(aggregate.total).toBe(3);
      expect(aggregate.healthy).toBe(2);
      expect(aggregate.unhealthy).toBe(1);
      expect(aggregate.healthPercentage).toBeCloseTo(66.67, 1);
      expect(aggregate.allHealthy).toBe(false);
      expect(aggregate.anyHealthy).toBe(true);
    });

    it('should return zero for empty monitor', () => {
      const monitor = new HealthMonitor();

      const aggregate = monitor.getAggregateHealth();

      expect(aggregate.total).toBe(0);
      expect(aggregate.healthPercentage).toBe(0);
      expect(aggregate.allHealthy).toBe(false);
    });
  });

  describe('getHealthyClients/getUnhealthyClients', () => {
    it('should return healthy client names', async () => {
      const monitor = new HealthMonitor({ failureThreshold: 1 });
      monitor.addClient('healthy1', createMockClient(true) as any);
      monitor.addClient('healthy2', createMockClient(true) as any);
      monitor.addClient('unhealthy', createMockClient(false) as any);

      await monitor.checkAll();

      const healthy = monitor.getHealthyClients();

      expect(healthy).toContain('healthy1');
      expect(healthy).toContain('healthy2');
      expect(healthy).not.toContain('unhealthy');
    });

    it('should return unhealthy client names', async () => {
      const monitor = new HealthMonitor({ failureThreshold: 1 });
      monitor.addClient('healthy', createMockClient(true) as any);
      monitor.addClient('unhealthy', createMockClient(false) as any);

      await monitor.checkAll();

      const unhealthy = monitor.getUnhealthyClients();

      expect(unhealthy).toContain('unhealthy');
      expect(unhealthy).not.toContain('healthy');
    });
  });

  describe('isHealthy', () => {
    it('should return true for healthy client', () => {
      const monitor = new HealthMonitor();
      monitor.addClient('test', createMockClient(true) as any);

      expect(monitor.isHealthy('test')).toBe(true);
    });

    it('should return false for unknown client', () => {
      const monitor = new HealthMonitor();

      expect(monitor.isHealthy('unknown')).toBe(false);
    });
  });

  describe('periodic checks', () => {
    it('should run checks at interval', async () => {
      const monitor = new HealthMonitor({
        interval: 1000,
      });
      const client = createMockClient(true);
      monitor.addClient('test', client as any);

      monitor.start();

      // Initial check
      expect(client.healthCheck).toHaveBeenCalledTimes(1);

      // Advance timer
      jest.advanceTimersByTime(1000);
      await Promise.resolve(); // Let promises settle

      expect(client.healthCheck).toHaveBeenCalledTimes(2);

      monitor.stop();
    });
  });
});

describe('createHealthMonitorForRouter', () => {
  it('should create monitor with router clients', () => {
    const router = new ModelRouter({
      models: [
        { name: 'model-1', endpoint: 'http://test:8000', model: 'test' },
        { name: 'model-2', endpoint: 'http://test:8001', model: 'test' },
      ],
    });

    const monitor = createHealthMonitorForRouter(router);

    expect(monitor.clientCount).toBe(2);
  });
});

describe('checkHealth', () => {
  it('should check health of multiple clients', async () => {
    const clients = new Map([
      ['healthy', createMockClient(true) as any],
      ['unhealthy', createMockClient(false) as any],
    ]);

    const results = await checkHealth(clients);

    expect(results).toHaveLength(2);
    expect(results.find((r) => r.name === 'healthy')?.healthy).toBe(true);
    expect(results.find((r) => r.name === 'unhealthy')?.healthy).toBe(false);
  });

  it('should include response time', async () => {
    const clients = new Map([['test', createMockClient(true) as any]]);

    const results = await checkHealth(clients);

    expect(results[0].responseTime).toBeGreaterThanOrEqual(0);
  });

  it('should handle errors', async () => {
    const errorClient = {
      healthCheck: jest.fn().mockRejectedValue(new Error('Connection failed')),
    };
    const clients = new Map([['error', errorClient as any]]);

    const results = await checkHealth(clients);

    expect(results[0].healthy).toBe(false);
    expect(results[0].error).toBe('Connection failed');
  });
});

describe('DEFAULT_HEALTH_MONITOR_CONFIG', () => {
  it('should have expected default values', () => {
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.interval).toBe(30000);
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.failureThreshold).toBe(3);
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.recoveryThreshold).toBe(1);
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.timeout).toBe(5000);
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.strategy).toBe('endpoint');
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.autoStart).toBe(false);
    expect(DEFAULT_HEALTH_MONITOR_CONFIG.debug).toBe(false);
  });
});