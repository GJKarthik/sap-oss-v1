/**
 * Model discovery and capability detection for vLLM instances.
 *
 * Provides automatic model discovery, capability detection, and router auto-configuration.
 */

import type { VllmConfig, VllmModel } from './types.js';
import { VllmChatClient } from './vllm-client.js';
import type { ModelRouter, RouterModelConfig, TaskType, ModelCapabilities } from './model-router.js';

/**
 * Discovered model information.
 */
export interface DiscoveredModel {
  /**
   * Model ID.
   */
  id: string;

  /**
   * vLLM endpoint.
   */
  endpoint: string;

  /**
   * Owner of the model.
   */
  ownedBy: string;

  /**
   * Creation timestamp.
   */
  created: number;

  /**
   * Detected capabilities.
   */
  capabilities: ModelCapabilities;

  /**
   * Suggested tasks based on model name/capabilities.
   */
  suggestedTasks: TaskType[];

  /**
   * Model family (llama, mistral, codellama, etc.)
   */
  family?: string;

  /**
   * Model size (7B, 13B, 70B, etc.)
   */
  size?: string;

  /**
   * Whether model supports chat format.
   */
  supportsChat: boolean;

  /**
   * Raw model info from vLLM.
   */
  raw: VllmModel;
}

/**
 * Model discovery configuration.
 */
export interface ModelDiscoveryConfig {
  /**
   * Timeout for discovery requests in milliseconds.
   * @default 10000
   */
  timeout?: number;

  /**
   * Whether to detect capabilities with test requests.
   * @default false
   */
  probeCapabilities?: boolean;

  /**
   * Cache TTL in milliseconds.
   * @default 60000
   */
  cacheTtl?: number;

  /**
   * Enable debug logging.
   * @default false
   */
  debug?: boolean;
}

/**
 * Default model discovery configuration.
 */
export const DEFAULT_DISCOVERY_CONFIG: Required<ModelDiscoveryConfig> = {
  timeout: 10000,
  probeCapabilities: false,
  cacheTtl: 60000,
  debug: false,
};

/**
 * Model family patterns for detection.
 */
const MODEL_FAMILY_PATTERNS: Array<{ pattern: RegExp; family: string; tasks: TaskType[] }> = [
  { pattern: /codellama|code-?llama|deepseek-?coder|starcoder|codestral/i, family: 'code', tasks: ['code'] },
  { pattern: /llama|vicuna|alpaca/i, family: 'llama', tasks: ['chat', 'creative', 'reasoning'] },
  { pattern: /mistral|mixtral/i, family: 'mistral', tasks: ['chat', 'reasoning'] },
  { pattern: /qwen/i, family: 'qwen', tasks: ['chat', 'reasoning'] },
  { pattern: /phi/i, family: 'phi', tasks: ['chat', 'reasoning'] },
  { pattern: /gemma/i, family: 'gemma', tasks: ['chat'] },
  { pattern: /falcon/i, family: 'falcon', tasks: ['chat'] },
  { pattern: /mpt/i, family: 'mpt', tasks: ['chat'] },
  { pattern: /embed|bge|e5|gte/i, family: 'embedding', tasks: ['embedding'] },
  { pattern: /summariz/i, family: 'summarization', tasks: ['summarization'] },
  { pattern: /translat/i, family: 'translation', tasks: ['translation'] },
];

/**
 * Model size patterns for detection.
 */
const MODEL_SIZE_PATTERNS: Array<{ pattern: RegExp; size: string; contextLength: number }> = [
  { pattern: /\b(1\.?[0-5]|1b)\b/i, size: '1B', contextLength: 4096 },
  { pattern: /\b(3b)\b/i, size: '3B', contextLength: 4096 },
  { pattern: /\b(7b)\b/i, size: '7B', contextLength: 8192 },
  { pattern: /\b(8b)\b/i, size: '8B', contextLength: 8192 },
  { pattern: /\b(13b)\b/i, size: '13B', contextLength: 8192 },
  { pattern: /\b(34b)\b/i, size: '34B', contextLength: 16384 },
  { pattern: /\b(70b)\b/i, size: '70B', contextLength: 32768 },
  { pattern: /\b(180b|405b)\b/i, size: '180B+', contextLength: 65536 },
];

/**
 * Cached discovery result.
 */
interface CachedDiscovery {
  models: DiscoveredModel[];
  timestamp: number;
}

/**
 * Discovers models from vLLM instances and detects their capabilities.
 *
 * @example
 * ```typescript
 * // Discover models from single endpoint
 * const discovery = new ModelDiscovery();
 * const models = await discovery.discover('http://vllm:8000');
 *
 * // Discover models from multiple endpoints
 * const allModels = await discovery.discoverAll([
 *   'http://vllm-1:8000',
 *   'http://vllm-2:8000',
 * ]);
 *
 * // Auto-configure router
 * const router = await discovery.createRouterFromEndpoints([
 *   'http://vllm-1:8000',
 *   'http://vllm-2:8000',
 * ]);
 * ```
 */
export class ModelDiscovery {
  private readonly config: Required<ModelDiscoveryConfig>;
  private readonly cache: Map<string, CachedDiscovery> = new Map();

  /**
   * Creates a new ModelDiscovery instance.
   * @param config - Discovery configuration
   */
  constructor(config: ModelDiscoveryConfig = {}) {
    this.config = {
      timeout: config.timeout ?? DEFAULT_DISCOVERY_CONFIG.timeout,
      probeCapabilities: config.probeCapabilities ?? DEFAULT_DISCOVERY_CONFIG.probeCapabilities,
      cacheTtl: config.cacheTtl ?? DEFAULT_DISCOVERY_CONFIG.cacheTtl,
      debug: config.debug ?? DEFAULT_DISCOVERY_CONFIG.debug,
    };

    this.log('ModelDiscovery initialized', this.config);
  }

  /**
   * Discovers models from a single endpoint.
   * @param endpoint - vLLM endpoint URL
   * @param useCache - Whether to use cached results
   * @returns Array of discovered models
   */
  async discover(endpoint: string, useCache = true): Promise<DiscoveredModel[]> {
    // Check cache
    if (useCache) {
      const cached = this.cache.get(endpoint);
      if (cached && Date.now() - cached.timestamp < this.config.cacheTtl) {
        this.log('Using cached discovery', { endpoint, age: Date.now() - cached.timestamp });
        return cached.models;
      }
    }

    this.log('Discovering models', { endpoint });

    const client = new VllmChatClient({ endpoint, model: '' });

    try {
      const rawModels = await client.listModels();
      const models: DiscoveredModel[] = [];

      for (const raw of rawModels) {
        const discovered = this.analyzeModel(raw, endpoint);

        // Optionally probe for capabilities
        if (this.config.probeCapabilities) {
          await this.probeModelCapabilities(discovered, client);
        }

        models.push(discovered);
      }

      // Cache results
      this.cache.set(endpoint, { models, timestamp: Date.now() });

      this.log('Discovery complete', { endpoint, modelCount: models.length });
      return models;
    } catch (error) {
      this.log('Discovery failed', { endpoint, error: (error as Error).message });
      throw error;
    }
  }

  /**
   * Discovers models from multiple endpoints.
   * @param endpoints - Array of vLLM endpoint URLs
   * @returns Array of all discovered models
   */
  async discoverAll(endpoints: string[]): Promise<DiscoveredModel[]> {
    const results = await Promise.allSettled(
      endpoints.map((endpoint) => this.discover(endpoint))
    );

    const allModels: DiscoveredModel[] = [];
    for (const result of results) {
      if (result.status === 'fulfilled') {
        allModels.push(...result.value);
      }
    }

    return allModels;
  }

  /**
   * Creates router configurations from discovered models.
   * @param endpoints - Array of vLLM endpoint URLs
   * @returns Array of router model configurations
   */
  async createRouterConfigs(endpoints: string[]): Promise<RouterModelConfig[]> {
    const models = await this.discoverAll(endpoints);
    return models.map((model) => this.toRouterConfig(model));
  }

  /**
   * Analyzes a raw model to detect its characteristics.
   */
  private analyzeModel(raw: VllmModel, endpoint: string): DiscoveredModel {
    const { family, tasks } = this.detectFamily(raw.id);
    const { size, contextLength } = this.detectSize(raw.id);
    const supportsChat = this.detectChatSupport(raw.id, family);

    const capabilities: ModelCapabilities = {
      maxContextLength: contextLength,
      streaming: true, // vLLM always supports streaming
      toolCalling: this.detectToolCallSupport(raw.id, family),
      jsonMode: this.detectJsonModeSupport(raw.id, family),
    };

    return {
      id: raw.id,
      endpoint,
      ownedBy: raw.owned_by,
      created: raw.created,
      capabilities,
      suggestedTasks: tasks,
      family,
      size,
      supportsChat,
      raw,
    };
  }

  /**
   * Detects model family and suggested tasks.
   */
  private detectFamily(modelId: string): { family?: string; tasks: TaskType[] } {
    for (const { pattern, family, tasks } of MODEL_FAMILY_PATTERNS) {
      if (pattern.test(modelId)) {
        return { family, tasks };
      }
    }
    return { family: undefined, tasks: ['chat'] };
  }

  /**
   * Detects model size and context length.
   */
  private detectSize(modelId: string): { size?: string; contextLength: number } {
    for (const { pattern, size, contextLength } of MODEL_SIZE_PATTERNS) {
      if (pattern.test(modelId)) {
        return { size, contextLength };
      }
    }
    return { size: undefined, contextLength: 4096 };
  }

  /**
   * Detects if model supports chat format.
   */
  private detectChatSupport(modelId: string, family?: string): boolean {
    // Embedding models don't support chat
    if (family === 'embedding') return false;

    // Check for instruct/chat indicators
    if (/instruct|chat/i.test(modelId)) return true;

    // Most modern models support chat
    return true;
  }

  /**
   * Detects if model supports tool/function calling.
   */
  private detectToolCallSupport(modelId: string, family?: string): boolean {
    // Known tool-calling models
    if (/llama-3\.1|mistral-?7b-instruct|mixtral/i.test(modelId)) return true;
    if (/tool|function/i.test(modelId)) return true;
    return false;
  }

  /**
   * Detects if model supports JSON mode.
   */
  private detectJsonModeSupport(modelId: string, family?: string): boolean {
    // Most instruct models support JSON
    if (/instruct/i.test(modelId)) return true;
    if (family === 'llama' || family === 'mistral') return true;
    return false;
  }

  /**
   * Probes model for capabilities via test requests.
   */
  private async probeModelCapabilities(
    model: DiscoveredModel,
    client: VllmChatClient
  ): Promise<void> {
    // This is optional and makes actual requests
    // Could probe for streaming, tool calling, etc.
    this.log('Probing capabilities', { model: model.id });
  }

  /**
   * Converts a discovered model to router configuration.
   */
  private toRouterConfig(model: DiscoveredModel): RouterModelConfig {
    // Generate unique name from endpoint and model
    const endpointName = new URL(model.endpoint).hostname.replace(/[^a-z0-9]/gi, '-');
    const name = `${endpointName}-${model.id.replace(/[^a-z0-9]/gi, '-')}`.toLowerCase();

    return {
      name,
      endpoint: model.endpoint,
      model: model.id,
      tasks: model.suggestedTasks,
      capabilities: model.capabilities,
      tags: [model.family, model.size].filter((t): t is string => !!t),
    };
  }

  /**
   * Clears the discovery cache.
   */
  clearCache(): void {
    this.cache.clear();
    this.log('Cache cleared');
  }

  /**
   * Clears cache for a specific endpoint.
   */
  clearCacheFor(endpoint: string): void {
    this.cache.delete(endpoint);
    this.log('Cache cleared for endpoint', { endpoint });
  }

  /**
   * Gets cache status.
   */
  getCacheStatus(): Map<string, { age: number; modelCount: number }> {
    const status = new Map<string, { age: number; modelCount: number }>();
    const now = Date.now();

    for (const [endpoint, cached] of this.cache.entries()) {
      status.set(endpoint, {
        age: now - cached.timestamp,
        modelCount: cached.models.length,
      });
    }

    return status;
  }

  /**
   * Logs a debug message if debug mode is enabled.
   */
  private log(message: string, data?: unknown): void {
    if (this.config.debug) {
      const timestamp = new Date().toISOString();
      // eslint-disable-next-line no-console
      console.log(`[ModelDiscovery ${timestamp}] ${message}`, data ?? '');
    }
  }
}

/**
 * Model filter predicate.
 */
export type ModelFilter = (model: DiscoveredModel) => boolean;

/**
 * Pre-built model filters.
 */
export const ModelFilters = {
  /**
   * Filter for chat-capable models.
   */
  chatCapable: (model: DiscoveredModel): boolean => model.supportsChat,

  /**
   * Filter for code models.
   */
  codeModels: (model: DiscoveredModel): boolean =>
    model.family === 'code' || model.suggestedTasks.includes('code'),

  /**
   * Filter for embedding models.
   */
  embeddingModels: (model: DiscoveredModel): boolean =>
    model.family === 'embedding' || model.suggestedTasks.includes('embedding'),

  /**
   * Filter by minimum context length.
   */
  minContextLength:
    (minLength: number): ModelFilter =>
    (model: DiscoveredModel): boolean =>
      (model.capabilities.maxContextLength ?? 0) >= minLength,

  /**
   * Filter by model family.
   */
  byFamily:
    (family: string): ModelFilter =>
    (model: DiscoveredModel): boolean =>
      model.family === family,

  /**
   * Filter by model size.
   */
  bySize:
    (size: string): ModelFilter =>
    (model: DiscoveredModel): boolean =>
      model.size === size,

  /**
   * Filter for tool-calling capable models.
   */
  toolCallCapable: (model: DiscoveredModel): boolean =>
    model.capabilities.toolCalling === true,

  /**
   * Combine multiple filters with AND.
   */
  all:
    (...filters: ModelFilter[]): ModelFilter =>
    (model: DiscoveredModel): boolean =>
      filters.every((f) => f(model)),

  /**
   * Combine multiple filters with OR.
   */
  any:
    (...filters: ModelFilter[]): ModelFilter =>
    (model: DiscoveredModel): boolean =>
      filters.some((f) => f(model)),
};

/**
 * Discovers a single model from an endpoint.
 * @param endpoint - vLLM endpoint
 * @returns First discovered model or undefined
 */
export async function discoverModel(endpoint: string): Promise<DiscoveredModel | undefined> {
  const discovery = new ModelDiscovery();
  const models = await discovery.discover(endpoint);
  return models[0];
}

/**
 * Gets model info as a summary string.
 */
export function formatModelInfo(model: DiscoveredModel): string {
  const parts = [model.id];
  if (model.family) parts.push(`[${model.family}]`);
  if (model.size) parts.push(model.size);
  if (model.capabilities.maxContextLength) {
    parts.push(`ctx:${model.capabilities.maxContextLength}`);
  }
  if (model.capabilities.toolCalling) parts.push('tools');
  return parts.join(' ');
}

/**
 * Groups discovered models by family.
 */
export function groupModelsByFamily(
  models: DiscoveredModel[]
): Map<string, DiscoveredModel[]> {
  const groups = new Map<string, DiscoveredModel[]>();

  for (const model of models) {
    const family = model.family ?? 'unknown';
    const existing = groups.get(family) ?? [];
    existing.push(model);
    groups.set(family, existing);
  }

  return groups;
}

/**
 * Groups discovered models by endpoint.
 */
export function groupModelsByEndpoint(
  models: DiscoveredModel[]
): Map<string, DiscoveredModel[]> {
  const groups = new Map<string, DiscoveredModel[]>();

  for (const model of models) {
    const existing = groups.get(model.endpoint) ?? [];
    existing.push(model);
    groups.set(model.endpoint, existing);
  }

  return groups;
}

/**
 * Finds the best model for a task.
 */
export function findBestModelForTask(
  models: DiscoveredModel[],
  task: TaskType
): DiscoveredModel | undefined {
  // First, find models that suggest this task
  const suitable = models.filter((m) => m.suggestedTasks.includes(task));

  if (suitable.length === 0) {
    // Fall back to chat-capable models for most tasks
    const chatModels = models.filter((m) => m.supportsChat);
    return chatModels[0];
  }

  // Prefer larger models
  return suitable.sort((a, b) => {
    const sizeA = a.capabilities.maxContextLength ?? 0;
    const sizeB = b.capabilities.maxContextLength ?? 0;
    return sizeB - sizeA;
  })[0];
}