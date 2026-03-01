// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Health monitoring for vLLM instances.
 *
 * Provides automatic health checking, status tracking, and router integration.
 */

import type { VllmHealthStatus, VllmModel } from './types.js';
import { VllmChatClient } from './vllm-client.js';
import type { ModelRouter, ModelStatus } from './model-router.js';

/**
 * Health check strategy.
 */
export type HealthCheckStrategy = 'endpoint' | 'models' | 'ping' | 'chat';

/**
 * Health status of a monitored model.
 */
export interface ModelHealthInfo {
  /**
   * Model name.
   */
  name: string;

  /**
   * Whether the model is healthy.
   */
  healthy: boolean;

  /**
   * Last health check timestamp.
   */
  lastCheck: number;

  /**
   * Last health status.
   */
  lastStatus?: VllmHealthStatus;

  /**
   * Number of consecutive failures.
   */
  consecutiveFailures: number;

  /**
   * Number of consecutive successes.
   */
  consecutiveSuccesses: number;

  /**
   * Error message if unhealthy.
   */
  error?: string;

  /**
   * Response time in milliseconds.
   */
  responseTime?: number;

  /**
   * Available models (if using 'models' strategy).
   */
  availableModels?: string[];
}

/**
 * Health monitor configuration.
 */
export interface HealthMonitorConfig {
  /**
   * Interval between health checks in milliseconds.
   * @default 30000
   */
  interval?: number;

  /**
   * Number of consecutive failures before marking unhealthy.
   * @default 3
   */
  failureThreshold?: number;

  /**
   * Number of consecutive successes before marking healthy.
   * @default 1
   */
  recoveryThreshold?: number;

  /**
   * Timeout for health check requests in milliseconds.
   * @default 5000
   */
  timeout?: number;

  /**
   * Health check strategy.
   * @default 'endpoint'
   */
  strategy?: HealthCheckStrategy;

  /**
   * Whether to start monitoring automatically.
   * @default false
   */
  autoStart?: boolean;

  /**
   * Router to update with health status.
   */
  router?: ModelRouter;

  /**
   * Enable debug logging.
   * @default false
   */
  debug?: boolean;
}

/**
 * Default health monitor configuration.
 */
export const DEFAULT_HEALTH_MONITOR_CONFIG: Required<Omit<HealthMonitorConfig, 'router'>> = {
  interval: 30000,
  failureThreshold: 3,
  recoveryThreshold: 1,
  timeout: 5000,
  strategy: 'endpoint',
  autoStart: false,
  debug: false,
};

/**
 * Health check result callback.
 */
export type HealthCheckCallback = (
  name: string,
  healthy: boolean,
  info: ModelHealthInfo,
  error?: Error
) => void;

/**
 * Health status change callback.
 */
export type HealthStatusChangeCallback = (
  name: string,
  previousStatus: boolean,
  newStatus: boolean,
  info: ModelHealthInfo
) => void;

/**
 * Aggregate health status.
 */
export interface AggregateHealth {
  /**
   * Total number of monitored clients.
   */
  total: number;

  /**
   * Number of healthy clients.
   */
  healthy: number;

  /**
   * Number of unhealthy clients.
   */
  unhealthy: number;

  /**
   * Overall health percentage.
   */
  healthPercentage: number;

  /**
   * Whether all clients are healthy.
   */
  allHealthy: boolean;

  /**
   * Whether any client is healthy.
   */
  anyHealthy: boolean;

  /**
   * Average response time across healthy clients.
   */
  averageResponseTime: number;

  /**
   * Last check timestamp.
   */
  lastCheck: number;
}

/**
 * Monitors health of vLLM instances and provides health status.
 *
 * @example
 * ```typescript
 * // Basic usage
 * const monitor = new HealthMonitor({
 *   interval: 30000,
 *   failureThreshold: 3,
 * });
 *
 * monitor.addClient('llama', llamaClient);
 * monitor.onHealthChange((name, healthy) => {
 *   console.log(`${name} is now ${healthy ? 'healthy' : 'unhealthy'}`);
 * });
 *
 * monitor.start();
 *
 * // With router integration
 * const router = new ModelRouter({ models: [...] });
 * const monitor = new HealthMonitor({
 *   router,
 *   interval: 15000,
 * });
 *
 * // Add clients from router
 * for (const name of router.listModels()) {
 *   monitor.addClient(name, router.getClientByName(name));
 * }
 *
 * monitor.start();
 * ```
 */
export class HealthMonitor {
  private readonly clients: Map<string, VllmChatClient> = new Map();
  private readonly health: Map<string, ModelHealthInfo> = new Map();
  private readonly config: Required<Omit<HealthMonitorConfig, 'router'>>;
  private readonly router?: ModelRouter;
  private readonly healthCallbacks: HealthCheckCallback[] = [];
  private readonly changeCallbacks: HealthStatusChangeCallback[] = [];
  private intervalId?: ReturnType<typeof setInterval>;
  private running = false;
  private checkInProgress = false;

  /**
   * Creates a new HealthMonitor instance.
   * @param config - Monitor configuration
   */
  constructor(config: HealthMonitorConfig = {}) {
    this.config = {
      interval: config.interval ?? DEFAULT_HEALTH_MONITOR_CONFIG.interval,
      failureThreshold: config.failureThreshold ?? DEFAULT_HEALTH_MONITOR_CONFIG.failureThreshold,
      recoveryThreshold: config.recoveryThreshold ?? DEFAULT_HEALTH_MONITOR_CONFIG.recoveryThreshold,
      timeout: config.timeout ?? DEFAULT_HEALTH_MONITOR_CONFIG.timeout,
      strategy: config.strategy ?? DEFAULT_HEALTH_MONITOR_CONFIG.strategy,
      autoStart: config.autoStart ?? DEFAULT_HEALTH_MONITOR_CONFIG.autoStart,
      debug: config.debug ?? DEFAULT_HEALTH_MONITOR_CONFIG.debug,
    };
    this.router = config.router;

    this.log('HealthMonitor initialized', this.config);

    if (this.config.autoStart) {
      this.start();
    }
  }

  /**
   * Adds a client to monitor.
   * @param name - Unique name for the client
   * @param client - VllmChatClient to monitor
   */
  addClient(name: string, client: VllmChatClient): void {
    this.clients.set(name, client);
    this.health.set(name, {
      name,
      healthy: true, // Assume healthy until first check
      lastCheck: 0,
      consecutiveFailures: 0,
      consecutiveSuccesses: 0,
    });

    this.log('Client added for monitoring', { name });
  }

  /**
   * Removes a client from monitoring.
   * @param name - Client name to remove
   * @returns True if client was removed
   */
  removeClient(name: string): boolean {
    const removed = this.clients.delete(name);
    this.health.delete(name);
    this.log('Client removed from monitoring', { name, removed });
    return removed;
  }

  /**
   * Registers a callback for health check results.
   * @param callback - Callback function
   */
  onHealthCheck(callback: HealthCheckCallback): void {
    this.healthCallbacks.push(callback);
  }

  /**
   * Registers a callback for health status changes.
   * @param callback - Callback function
   */
  onHealthChange(callback: HealthStatusChangeCallback): void {
    this.changeCallbacks.push(callback);
  }

  /**
   * Starts periodic health monitoring.
   */
  start(): void {
    if (this.running) {
      this.log('Monitor already running');
      return;
    }

    this.running = true;
    this.log('Starting health monitoring');

    // Run initial check immediately
    void this.checkAll();

    // Set up periodic checks
    this.intervalId = setInterval(() => {
      void this.checkAll();
    }, this.config.interval);
  }

  /**
   * Stops periodic health monitoring.
   */
  stop(): void {
    if (!this.running) {
      this.log('Monitor not running');
      return;
    }

    this.running = false;
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = undefined;
    }

    this.log('Stopped health monitoring');
  }

  /**
   * Checks health of all registered clients.
   */
  async checkAll(): Promise<Map<string, ModelHealthInfo>> {
    if (this.checkInProgress) {
      this.log('Check already in progress, skipping');
      return new Map(this.health);
    }

    this.checkInProgress = true;
    this.log('Starting health check for all clients');

    try {
      const checks = Array.from(this.clients.entries()).map(([name, client]) =>
        this.checkClient(name, client)
      );

      await Promise.allSettled(checks);
    } finally {
      this.checkInProgress = false;
    }

    return new Map(this.health);
  }

  /**
   * Checks health of a specific client.
   * @param name - Client name
   * @returns Health info
   */
  async check(name: string): Promise<ModelHealthInfo | undefined> {
    const client = this.clients.get(name);
    if (!client) {
      return undefined;
    }

    await this.checkClient(name, client);
    return this.health.get(name);
  }

  /**
   * Gets current health info for a client.
   * @param name - Client name
   * @returns Health info or undefined
   */
  getHealth(name: string): ModelHealthInfo | undefined {
    return this.health.get(name);
  }

  /**
   * Gets all health info.
   * @returns Map of name to health info
   */
  getAllHealth(): Map<string, ModelHealthInfo> {
    return new Map(this.health);
  }

  /**
   * Gets aggregate health status.
   * @returns Aggregate health info
   */
  getAggregateHealth(): AggregateHealth {
    const healthInfos = Array.from(this.health.values());
    const healthyClients = healthInfos.filter((h) => h.healthy);
    const total = healthInfos.length;
    const healthy = healthyClients.length;

    // Calculate average response time from healthy clients
    const responseTimes = healthyClients
      .map((h) => h.responseTime)
      .filter((t): t is number => t !== undefined);
    const averageResponseTime =
      responseTimes.length > 0
        ? responseTimes.reduce((sum, t) => sum + t, 0) / responseTimes.length
        : 0;

    // Find most recent check
    const lastCheck = Math.max(...healthInfos.map((h) => h.lastCheck), 0);

    return {
      total,
      healthy,
      unhealthy: total - healthy,
      healthPercentage: total > 0 ? (healthy / total) * 100 : 0,
      allHealthy: healthy === total && total > 0,
      anyHealthy: healthy > 0,
      averageResponseTime,
      lastCheck,
    };
  }

  /**
   * Gets list of healthy clients.
   * @returns Array of healthy client names
   */
  getHealthyClients(): string[] {
    return Array.from(this.health.entries())
      .filter(([, info]) => info.healthy)
      .map(([name]) => name);
  }

  /**
   * Gets list of unhealthy clients.
   * @returns Array of unhealthy client names
   */
  getUnhealthyClients(): string[] {
    return Array.from(this.health.entries())
      .filter(([, info]) => !info.healthy)
      .map(([name]) => name);
  }

  /**
   * Checks if a specific client is healthy.
   * @param name - Client name
   * @returns True if healthy
   */
  isHealthy(name: string): boolean {
    return this.health.get(name)?.healthy ?? false;
  }

  /**
   * Checks if the monitor is running.
   */
  get isRunning(): boolean {
    return this.running;
  }

  /**
   * Gets the number of monitored clients.
   */
  get clientCount(): number {
    return this.clients.size;
  }

  /**
   * Performs health check on a single client.
   */
  private async checkClient(name: string, client: VllmChatClient): Promise<void> {
    const info = this.health.get(name);
    if (!info) return;

    const previousHealth = info.healthy;
    const startTime = Date.now();

    try {
      let status: VllmHealthStatus;
      let availableModels: string[] | undefined;

      switch (this.config.strategy) {
        case 'models':
          const models = await this.checkModels(client);
          availableModels = models.map((m) => m.id);
          status = {
            healthy: models.length > 0,
            status: models.length > 0 ? 'ok' : 'no_models',
            timestamp: Date.now(),
            modelCount: models.length,
          };
          break;

        case 'ping':
          status = await this.checkPing(client);
          break;

        case 'chat':
          status = await this.checkChat(client);
          break;

        case 'endpoint':
        default:
          status = await this.checkEndpoint(client);
          break;
      }

      const responseTime = Date.now() - startTime;

      info.lastCheck = Date.now();
      info.lastStatus = status;
      info.responseTime = responseTime;
      info.error = undefined;
      info.availableModels = availableModels;

      if (status.healthy) {
        info.consecutiveSuccesses++;
        info.consecutiveFailures = 0;

        // Check recovery threshold
        if (!info.healthy && info.consecutiveSuccesses >= this.config.recoveryThreshold) {
          info.healthy = true;
        } else if (info.healthy) {
          info.healthy = true;
        }
      } else {
        info.consecutiveFailures++;
        info.consecutiveSuccesses = 0;

        if (info.consecutiveFailures >= this.config.failureThreshold) {
          info.healthy = false;
        }
      }

      // Update router if configured
      if (this.router) {
        this.updateRouter(name, info.healthy);
      }

      // Notify callbacks
      this.notifyHealthCallbacks(name, info.healthy, info);

      // Notify change callbacks if health changed
      if (previousHealth !== info.healthy) {
        this.notifyChangeCallbacks(name, previousHealth, info.healthy, info);
      }

      this.log('Health check completed', {
        name,
        healthy: info.healthy,
        responseTime,
        strategy: this.config.strategy,
      });
    } catch (error) {
      const responseTime = Date.now() - startTime;

      info.lastCheck = Date.now();
      info.consecutiveFailures++;
      info.consecutiveSuccesses = 0;
      info.error = error instanceof Error ? error.message : String(error);
      info.responseTime = responseTime;

      if (info.consecutiveFailures >= this.config.failureThreshold) {
        info.healthy = false;
      }

      // Update router if configured
      if (this.router) {
        this.updateRouter(name, info.healthy);
      }

      // Notify callbacks
      this.notifyHealthCallbacks(name, info.healthy, info, error as Error);

      // Notify change callbacks if health changed
      if (previousHealth !== info.healthy) {
        this.notifyChangeCallbacks(name, previousHealth, info.healthy, info);
      }

      this.log('Health check failed', {
        name,
        error: info.error,
        consecutiveFailures: info.consecutiveFailures,
      });
    }
  }

  /**
   * Checks health using the /health endpoint.
   */
  private async checkEndpoint(client: VllmChatClient): Promise<VllmHealthStatus> {
    const result = await client.healthCheck();
    return result;
  }

  /**
   * Checks health by listing models.
   */
  private async checkModels(client: VllmChatClient): Promise<VllmModel[]> {
    const models = await client.listModels();
    return models;
  }

  /**
   * Checks health with a ping (minimal request).
   */
  private async checkPing(client: VllmChatClient): Promise<VllmHealthStatus> {
    // Use healthCheck for ping
    const result = await client.healthCheck();
    return {
      healthy: result.healthy,
      status: result.status,
      timestamp: Date.now(),
    };
  }

  /**
   * Checks health by making a minimal chat request.
   */
  private async checkChat(client: VllmChatClient): Promise<VllmHealthStatus> {
    try {
      await client.chat({
        messages: [{ role: 'user', content: 'ping' }],
        maxTokens: 1,
      });

      return {
        healthy: true,
        status: 'ok',
        timestamp: Date.now(),
      };
    } catch (error) {
      return {
        healthy: false,
        status: 'error',
        timestamp: Date.now(),
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  /**
   * Updates router with model status.
   */
  private updateRouter(name: string, healthy: boolean): void {
    if (!this.router) return;

    const status: ModelStatus = healthy ? 'healthy' : 'unhealthy';
    this.router.setModelStatus(name, status);
  }

  /**
   * Notifies registered health callbacks.
   */
  private notifyHealthCallbacks(
    name: string,
    healthy: boolean,
    info: ModelHealthInfo,
    error?: Error
  ): void {
    for (const callback of this.healthCallbacks) {
      try {
        callback(name, healthy, info, error);
      } catch {
        // Ignore callback errors
      }
    }
  }

  /**
   * Notifies registered change callbacks.
   */
  private notifyChangeCallbacks(
    name: string,
    previousStatus: boolean,
    newStatus: boolean,
    info: ModelHealthInfo
  ): void {
    for (const callback of this.changeCallbacks) {
      try {
        callback(name, previousStatus, newStatus, info);
      } catch {
        // Ignore callback errors
      }
    }
  }

  /**
   * Logs a debug message if debug mode is enabled.
   */
  private log(message: string, data?: unknown): void {
    if (this.config.debug) {
      const timestamp = new Date().toISOString();
      // eslint-disable-next-line no-console
      console.log(`[HealthMonitor ${timestamp}] ${message}`, data ?? '');
    }
  }
}

/**
 * Creates a health monitor for a router.
 * @param router - ModelRouter to monitor
 * @param config - Monitor configuration
 * @returns Configured HealthMonitor
 */
export function createHealthMonitorForRouter(
  router: ModelRouter,
  config: Partial<HealthMonitorConfig> = {}
): HealthMonitor {
  const monitor = new HealthMonitor({
    ...config,
    router,
  });

  // Add all clients from router
  for (const name of router.listModels()) {
    monitor.addClient(name, router.getClientByName(name));
  }

  return monitor;
}

/**
 * Health check result.
 */
export interface HealthCheckResult {
  name: string;
  healthy: boolean;
  responseTime: number;
  error?: string;
}

/**
 * Performs a one-time health check on multiple clients.
 * @param clients - Map of name to client
 * @param timeout - Timeout in milliseconds
 * @returns Array of health check results
 */
export async function checkHealth(
  clients: Map<string, VllmChatClient>,
  timeout = 5000
): Promise<HealthCheckResult[]> {
  const results: HealthCheckResult[] = [];

  const checks = Array.from(clients.entries()).map(async ([name, client]) => {
    const startTime = Date.now();
    try {
      const status = await client.healthCheck();
      results.push({
        name,
        healthy: status.healthy,
        responseTime: Date.now() - startTime,
      });
    } catch (error) {
      results.push({
        name,
        healthy: false,
        responseTime: Date.now() - startTime,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });

  await Promise.allSettled(checks);
  return results;
}