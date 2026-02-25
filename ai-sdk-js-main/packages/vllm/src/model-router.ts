/**
 * Multi-model router for vLLM instances.
 *
 * Provides intelligent routing to multiple vLLM backends based on:
 * - Task type (chat, code, analysis, embedding)
 * - Load balancing (round-robin, weighted, random)
 * - Health status
 * - Model capabilities
 */

import type { VllmConfig, VllmChatMessage, VllmChatRequest, VllmChatResponse } from './types.js';
import { VllmChatClient } from './vllm-client.js';

/**
 * Task types for routing.
 */
export type TaskType =
  | 'chat'
  | 'code'
  | 'analysis'
  | 'embedding'
  | 'summarization'
  | 'translation'
  | 'creative'
  | 'reasoning'
  | 'default';

/**
 * Load balancing strategies.
 */
export type LoadBalanceStrategy = 'round-robin' | 'weighted' | 'random' | 'least-latency' | 'priority';

/**
 * Model status.
 */
export type ModelStatus = 'healthy' | 'degraded' | 'unhealthy' | 'unknown';

/**
 * Model capabilities.
 */
export interface ModelCapabilities {
  /**
   * Maximum context length in tokens.
   */
  maxContextLength?: number;

  /**
   * Whether the model supports streaming.
   */
  streaming?: boolean;

  /**
   * Whether the model supports function/tool calling.
   */
  toolCalling?: boolean;

  /**
   * Whether the model supports JSON mode.
   */
  jsonMode?: boolean;

  /**
   * Languages the model supports.
   */
  languages?: string[];

  /**
   * Custom capabilities.
   */
  custom?: Record<string, unknown>;
}

/**
 * Configuration for a model in the router.
 */
export interface RouterModelConfig extends VllmConfig {
  /**
   * Unique name for this model instance.
   */
  name: string;

  /**
   * Tasks this model is suitable for.
   */
  tasks?: TaskType[];

  /**
   * Priority for load balancing (higher = preferred).
   * @default 1
   */
  priority?: number;

  /**
   * Weight for weighted load balancing.
   * @default 1
   */
  weight?: number;

  /**
   * Model capabilities.
   */
  capabilities?: ModelCapabilities;

  /**
   * Tags for filtering.
   */
  tags?: string[];

  /**
   * Whether this model is enabled.
   * @default true
   */
  enabled?: boolean;
}

/**
 * Model router configuration.
 */
export interface ModelRouterConfig {
  /**
   * Models to register with the router.
   */
  models: RouterModelConfig[];

  /**
   * Task-to-model mapping.
   */
  taskMapping?: Partial<Record<TaskType, string | string[]>>;

  /**
   * Default model name.
   */
  defaultModel?: string;

  /**
   * Load balancing strategy.
   * @default 'round-robin'
   */
  loadBalanceStrategy?: LoadBalanceStrategy;

  /**
   * Whether to skip unhealthy models.
   * @default true
   */
  skipUnhealthy?: boolean;

  /**
   * Enable debug logging.
   * @default false
   */
  debug?: boolean;
}

/**
 * Model state tracked by the router.
 */
interface ModelState {
  config: RouterModelConfig;
  client: VllmChatClient;
  status: ModelStatus;
  requestCount: number;
  errorCount: number;
  totalLatency: number;
  lastUsed?: Date;
  lastError?: Error;
  lastHealthCheck?: Date;
}

/**
 * Routes requests to appropriate vLLM instances based on task, load balancing, or configuration.
 *
 * @example
 * ```typescript
 * // Basic setup
 * const router = new ModelRouter({
 *   models: [
 *     { name: 'llama', endpoint: 'http://vllm-1:8000', model: 'meta-llama/Llama-3.1-70B', tasks: ['chat'] },
 *     { name: 'codellama', endpoint: 'http://vllm-2:8000', model: 'codellama/CodeLlama-34b', tasks: ['code'] },
 *   ],
 *   defaultModel: 'llama',
 * });
 *
 * // Get client by task
 * const chatClient = router.getClient('chat');
 *
 * // Get client by name
 * const codeClient = router.getClientByName('codellama');
 *
 * // Load balanced selection
 * const client = router.getBalancedClient();
 *
 * // Chat through router
 * const response = await router.chat(messages, { task: 'code' });
 * ```
 */
export class ModelRouter {
  private readonly models: Map<string, ModelState> = new Map();
  private readonly taskMapping: Map<TaskType, string[]> = new Map();
  private readonly loadBalanceStrategy: LoadBalanceStrategy;
  private readonly skipUnhealthy: boolean;
  private readonly debug: boolean;
  private defaultModel?: string;
  private roundRobinCounters: Map<string, number> = new Map();

  /**
   * Creates a new ModelRouter instance.
   * @param config - Router configuration
   */
  constructor(config: ModelRouterConfig) {
    this.loadBalanceStrategy = config.loadBalanceStrategy ?? 'round-robin';
    this.skipUnhealthy = config.skipUnhealthy ?? true;
    this.debug = config.debug ?? false;

    // Register models
    for (const modelConfig of config.models) {
      this.registerModel(modelConfig);
    }

    // Set up task mapping
    if (config.taskMapping) {
      for (const [task, modelNames] of Object.entries(config.taskMapping)) {
        const names = Array.isArray(modelNames) ? modelNames : [modelNames];
        this.taskMapping.set(task as TaskType, names);
        this.roundRobinCounters.set(task, 0);
      }
    }

    // Set default model
    this.defaultModel = config.defaultModel ?? config.models[0]?.name;

    this.log('ModelRouter initialized', {
      modelCount: this.models.size,
      defaultModel: this.defaultModel,
      loadBalanceStrategy: this.loadBalanceStrategy,
    });
  }

  /**
   * Registers a new model with the router.
   * @param config - Model configuration
   */
  registerModel(config: RouterModelConfig): void {
    if (config.enabled === false) {
      this.log('Skipping disabled model', { name: config.name });
      return;
    }

    const client = new VllmChatClient(config);
    const state: ModelState = {
      config,
      client,
      status: 'unknown',
      requestCount: 0,
      errorCount: 0,
      totalLatency: 0,
    };

    this.models.set(config.name, state);

    // Register task mappings for this model
    if (config.tasks) {
      for (const task of config.tasks) {
        const existing = this.taskMapping.get(task) ?? [];
        if (!existing.includes(config.name)) {
          this.taskMapping.set(task, [...existing, config.name]);
        }
        if (!this.roundRobinCounters.has(task)) {
          this.roundRobinCounters.set(task, 0);
        }
      }
    }

    this.log('Model registered', { name: config.name, model: config.model, tasks: config.tasks });
  }

  /**
   * Removes a model from the router.
   * @param name - Model name to remove
   * @returns True if the model was removed
   */
  removeModel(name: string): boolean {
    const removed = this.models.delete(name);

    // Clean up task mappings
    for (const [task, modelNames] of this.taskMapping.entries()) {
      const filtered = modelNames.filter((n) => n !== name);
      if (filtered.length > 0) {
        this.taskMapping.set(task, filtered);
      } else {
        this.taskMapping.delete(task);
      }
    }

    if (this.defaultModel === name) {
      this.defaultModel = this.models.keys().next().value;
    }

    this.log('Model removed', { name, removed });
    return removed;
  }

  /**
   * Gets a client for the specified task.
   * @param task - Task type
   * @returns Client for the task, or default client
   */
  getClient(task: TaskType): VllmChatClient {
    const modelNames = this.taskMapping.get(task);

    if (modelNames && modelNames.length > 0) {
      // Use load balancing if multiple models for this task
      if (modelNames.length > 1) {
        return this.getBalancedClientFromList(modelNames, task);
      }
      return this.getClientByName(modelNames[0]);
    }

    // Fall back to default
    if (!this.defaultModel) {
      throw new Error(`No model available for task: ${task}`);
    }

    return this.getClientByName(this.defaultModel);
  }

  /**
   * Gets a client using load balancing.
   * @returns Load-balanced client
   */
  getBalancedClient(): VllmChatClient {
    const modelNames = Array.from(this.models.keys());
    if (modelNames.length === 0) {
      throw new Error('No models registered');
    }

    return this.getBalancedClientFromList(modelNames, 'default');
  }

  /**
   * Gets a load-balanced client from a list of model names.
   */
  private getBalancedClientFromList(modelNames: string[], contextKey: string): VllmChatClient {
    const availableModels = this.getAvailableModels(modelNames);

    if (availableModels.length === 0) {
      throw new Error('No available models for selection');
    }

    let selectedName: string;

    switch (this.loadBalanceStrategy) {
      case 'round-robin':
        selectedName = this.selectRoundRobin(availableModels, contextKey);
        break;
      case 'weighted':
        selectedName = this.selectWeighted(availableModels);
        break;
      case 'random':
        selectedName = this.selectRandom(availableModels);
        break;
      case 'least-latency':
        selectedName = this.selectLeastLatency(availableModels);
        break;
      case 'priority':
        selectedName = this.selectByPriority(availableModels);
        break;
      default:
        selectedName = availableModels[0];
    }

    this.log('Load balanced selection', { strategy: this.loadBalanceStrategy, selected: selectedName });
    return this.getClientByName(selectedName);
  }

  /**
   * Gets available (healthy) models from a list.
   */
  private getAvailableModels(modelNames: string[]): string[] {
    if (!this.skipUnhealthy) {
      return modelNames;
    }

    return modelNames.filter((name) => {
      const state = this.models.get(name);
      return state && state.status !== 'unhealthy';
    });
  }

  /**
   * Round-robin selection.
   */
  private selectRoundRobin(modelNames: string[], contextKey: string): string {
    const counter = this.roundRobinCounters.get(contextKey) ?? 0;
    const index = counter % modelNames.length;
    this.roundRobinCounters.set(contextKey, counter + 1);
    return modelNames[index];
  }

  /**
   * Weighted random selection.
   */
  private selectWeighted(modelNames: string[]): string {
    const weights = modelNames.map((name) => {
      const state = this.models.get(name);
      return state?.config.weight ?? 1;
    });

    const totalWeight = weights.reduce((sum, w) => sum + w, 0);
    let random = Math.random() * totalWeight;

    for (let i = 0; i < modelNames.length; i++) {
      random -= weights[i];
      if (random <= 0) {
        return modelNames[i];
      }
    }

    return modelNames[modelNames.length - 1];
  }

  /**
   * Random selection.
   */
  private selectRandom(modelNames: string[]): string {
    const index = Math.floor(Math.random() * modelNames.length);
    return modelNames[index];
  }

  /**
   * Least latency selection.
   */
  private selectLeastLatency(modelNames: string[]): string {
    let bestName = modelNames[0];
    let bestLatency = Infinity;

    for (const name of modelNames) {
      const state = this.models.get(name);
      if (state && state.requestCount > 0) {
        const avgLatency = state.totalLatency / state.requestCount;
        if (avgLatency < bestLatency) {
          bestLatency = avgLatency;
          bestName = name;
        }
      }
    }

    return bestName;
  }

  /**
   * Priority-based selection.
   */
  private selectByPriority(modelNames: string[]): string {
    let bestName = modelNames[0];
    let bestPriority = -Infinity;

    for (const name of modelNames) {
      const state = this.models.get(name);
      const priority = state?.config.priority ?? 1;
      if (priority > bestPriority) {
        bestPriority = priority;
        bestName = name;
      }
    }

    return bestName;
  }

  /**
   * Gets a client by model name.
   * @param name - Model name
   * @returns Client for the model
   */
  getClientByName(name: string): VllmChatClient {
    const state = this.models.get(name);
    if (!state) {
      throw new Error(`Model not found: ${name}`);
    }
    return state.client;
  }

  /**
   * Gets the default client.
   * @returns Default client
   */
  getDefaultClient(): VllmChatClient {
    if (!this.defaultModel) {
      throw new Error('No default model configured');
    }
    return this.getClientByName(this.defaultModel);
  }

  /**
   * Sets the default model.
   * @param name - Model name to set as default
   */
  setDefaultModel(name: string): void {
    if (!this.models.has(name)) {
      throw new Error(`Model not found: ${name}`);
    }
    this.defaultModel = name;
    this.log('Default model changed', { name });
  }

  /**
   * Gets the default model name.
   */
  getDefaultModelName(): string | undefined {
    return this.defaultModel;
  }

  /**
   * Sets task mapping.
   * @param task - Task type
   * @param modelNames - Model name(s) to use for the task
   */
  setTaskMapping(task: TaskType, modelNames: string | string[]): void {
    const names = Array.isArray(modelNames) ? modelNames : [modelNames];
    for (const name of names) {
      if (!this.models.has(name)) {
        throw new Error(`Model not found: ${name}`);
      }
    }
    this.taskMapping.set(task, names);
    if (!this.roundRobinCounters.has(task)) {
      this.roundRobinCounters.set(task, 0);
    }
    this.log('Task mapping updated', { task, modelNames: names });
  }

  /**
   * Updates model status.
   * @param name - Model name
   * @param status - New status
   */
  setModelStatus(name: string, status: ModelStatus): void {
    const state = this.models.get(name);
    if (state) {
      state.status = status;
      state.lastHealthCheck = new Date();
      this.log('Model status updated', { name, status });
    }
  }

  /**
   * Records a successful request.
   * @param name - Model name
   * @param latencyMs - Request latency in milliseconds
   */
  recordSuccess(name: string, latencyMs: number): void {
    const state = this.models.get(name);
    if (state) {
      state.requestCount++;
      state.totalLatency += latencyMs;
      state.lastUsed = new Date();
      if (state.status === 'unknown') {
        state.status = 'healthy';
      }
    }
  }

  /**
   * Records a failed request.
   * @param name - Model name
   * @param error - Error that occurred
   */
  recordError(name: string, error: Error): void {
    const state = this.models.get(name);
    if (state) {
      state.errorCount++;
      state.lastError = error;
      state.lastUsed = new Date();

      // Degrade status based on error count
      const errorRate = state.errorCount / (state.requestCount + 1);
      if (errorRate > 0.5) {
        state.status = 'unhealthy';
      } else if (errorRate > 0.2) {
        state.status = 'degraded';
      }
    }
  }

  /**
   * Lists all registered model names.
   * @returns Array of model names
   */
  listModels(): string[] {
    return Array.from(this.models.keys());
  }

  /**
   * Lists models for a specific task.
   * @param task - Task type
   * @returns Array of model names
   */
  listModelsForTask(task: TaskType): string[] {
    return this.taskMapping.get(task) ?? [];
  }

  /**
   * Lists models with a specific tag.
   * @param tag - Tag to filter by
   * @returns Array of model names
   */
  listModelsByTag(tag: string): string[] {
    const result: string[] = [];
    for (const [name, state] of this.models.entries()) {
      if (state.config.tags?.includes(tag)) {
        result.push(name);
      }
    }
    return result;
  }

  /**
   * Gets configuration for a model.
   * @param name - Model name
   * @returns Model configuration or undefined
   */
  getModelConfig(name: string): RouterModelConfig | undefined {
    return this.models.get(name)?.config;
  }

  /**
   * Gets status for a model.
   * @param name - Model name
   * @returns Model status or undefined
   */
  getModelStatus(name: string): ModelStatus | undefined {
    return this.models.get(name)?.status;
  }

  /**
   * Gets stats for a model.
   * @param name - Model name
   * @returns Model stats
   */
  getModelStats(name: string): ModelStats | undefined {
    const state = this.models.get(name);
    if (!state) return undefined;

    return {
      name,
      status: state.status,
      requestCount: state.requestCount,
      errorCount: state.errorCount,
      errorRate: state.requestCount > 0 ? state.errorCount / state.requestCount : 0,
      averageLatency: state.requestCount > 0 ? state.totalLatency / state.requestCount : 0,
      lastUsed: state.lastUsed,
      lastError: state.lastError?.message,
    };
  }

  /**
   * Gets stats for all models.
   * @returns Array of model stats
   */
  getAllStats(): ModelStats[] {
    return this.listModels()
      .map((name) => this.getModelStats(name))
      .filter((s): s is ModelStats => s !== undefined);
  }

  /**
   * Gets all task mappings.
   * @returns Map of task to model names
   */
  getTaskMappings(): Map<TaskType, string[]> {
    return new Map(this.taskMapping);
  }

  /**
   * Gets the number of registered models.
   */
  get size(): number {
    return this.models.size;
  }

  /**
   * Sends a chat request through the router.
   * @param messages - Chat messages
   * @param options - Request options
   * @returns Chat response
   */
  async chat(
    messages: VllmChatMessage[],
    options: ChatOptions = {}
  ): Promise<VllmChatResponse> {
    const client = options.modelName
      ? this.getClientByName(options.modelName)
      : options.task
        ? this.getClient(options.task)
        : this.getBalancedClient();

    const modelName = this.findModelName(client);
    const startTime = Date.now();

    try {
      const response = await client.chat({
        messages,
        ...options.requestOptions,
      });
      this.recordSuccess(modelName, Date.now() - startTime);
      return response;
    } catch (error) {
      this.recordError(modelName, error as Error);
      throw error;
    }
  }

  /**
   * Finds the model name for a client.
   */
  private findModelName(client: VllmChatClient): string {
    for (const [name, state] of this.models.entries()) {
      if (state.client === client) {
        return name;
      }
    }
    return 'unknown';
  }

  /**
   * Resets all statistics.
   */
  resetStats(): void {
    for (const state of this.models.values()) {
      state.requestCount = 0;
      state.errorCount = 0;
      state.totalLatency = 0;
      state.lastUsed = undefined;
      state.lastError = undefined;
    }
    this.log('Statistics reset');
  }

  /**
   * Logs a debug message if debug mode is enabled.
   */
  private log(message: string, data?: Record<string, unknown>): void {
    if (this.debug) {
      const timestamp = new Date().toISOString();
      // eslint-disable-next-line no-console
      console.log(`[ModelRouter ${timestamp}] ${message}`, data ?? '');
    }
  }
}

/**
 * Model statistics.
 */
export interface ModelStats {
  name: string;
  status: ModelStatus;
  requestCount: number;
  errorCount: number;
  errorRate: number;
  averageLatency: number;
  lastUsed?: Date;
  lastError?: string;
}

/**
 * Options for chat through router.
 */
export interface ChatOptions {
  /**
   * Task type for routing.
   */
  task?: TaskType;

  /**
   * Specific model name to use.
   */
  modelName?: string;

  /**
   * Additional request options.
   */
  requestOptions?: Partial<VllmChatRequest>;
}

/**
 * Creates a simple router with multiple endpoints for the same model.
 */
export function createLoadBalancedRouter(
  endpoints: string[],
  model: string,
  options: Partial<ModelRouterConfig> = {}
): ModelRouter {
  const models: RouterModelConfig[] = endpoints.map((endpoint, index) => ({
    name: `${model}-${index}`,
    endpoint,
    model,
    weight: 1,
  }));

  return new ModelRouter({
    models,
    loadBalanceStrategy: 'round-robin',
    ...options,
  });
}

/**
 * Creates a router with task-specialized models.
 */
export function createTaskRouter(
  taskModels: Record<TaskType, RouterModelConfig>,
  defaultTask: TaskType = 'chat'
): ModelRouter {
  const models = Object.values(taskModels);
  const taskMapping: Partial<Record<TaskType, string>> = {};

  for (const [task, config] of Object.entries(taskModels)) {
    taskMapping[task as TaskType] = config.name;
  }

  return new ModelRouter({
    models,
    taskMapping,
    defaultModel: taskModels[defaultTask]?.name,
  });
}