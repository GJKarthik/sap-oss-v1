/**
 * @sap-ai-sdk/elasticsearch - Ingest Pipeline
 *
 * Helpers for creating Elasticsearch ingest pipelines
 * for automatic document processing and embedding generation.
 */

import type { Client } from '@elastic/elasticsearch';
import { wrapError } from './errors.js';

// ============================================================================
// Types
// ============================================================================

/**
 * Processor configuration base
 */
export interface ProcessorConfig {
  /** Processor type */
  type: string;
  /** Optional tag */
  tag?: string;
  /** Optional description */
  description?: string;
  /** Condition for execution */
  if?: string;
  /** Ignore failures */
  ignoreFailure?: boolean;
  /** On failure processors */
  onFailure?: ProcessorConfig[];
}

/**
 * Set processor configuration
 */
export interface SetProcessorConfig extends ProcessorConfig {
  type: 'set';
  /** Field to set */
  field: string;
  /** Value to set */
  value: unknown;
  /** Override existing value */
  override?: boolean;
  /** Ignore empty value */
  ignoreEmptyValue?: boolean;
}

/**
 * Remove processor configuration
 */
export interface RemoveProcessorConfig extends ProcessorConfig {
  type: 'remove';
  /** Field to remove */
  field: string | string[];
}

/**
 * Rename processor configuration
 */
export interface RenameProcessorConfig extends ProcessorConfig {
  type: 'rename';
  /** Source field */
  field: string;
  /** Target field */
  targetField: string;
}

/**
 * Script processor configuration
 */
export interface ScriptProcessorConfig extends ProcessorConfig {
  type: 'script';
  /** Script source */
  source: string;
  /** Script language */
  lang?: string;
  /** Script parameters */
  params?: Record<string, unknown>;
}

/**
 * Convert processor configuration
 */
export interface ConvertProcessorConfig extends ProcessorConfig {
  type: 'convert';
  /** Field to convert */
  field: string;
  /** Target type */
  targetType: 'integer' | 'long' | 'float' | 'double' | 'string' | 'boolean' | 'auto';
  /** Target field (optional) */
  targetField?: string;
}

/**
 * Lowercase processor configuration
 */
export interface LowercaseProcessorConfig extends ProcessorConfig {
  type: 'lowercase';
  /** Field to lowercase */
  field: string;
  /** Target field (optional) */
  targetField?: string;
}

/**
 * Uppercase processor configuration
 */
export interface UppercaseProcessorConfig extends ProcessorConfig {
  type: 'uppercase';
  /** Field to uppercase */
  field: string;
  /** Target field (optional) */
  targetField?: string;
}

/**
 * Trim processor configuration
 */
export interface TrimProcessorConfig extends ProcessorConfig {
  type: 'trim';
  /** Field to trim */
  field: string;
  /** Target field (optional) */
  targetField?: string;
}

/**
 * Split processor configuration
 */
export interface SplitProcessorConfig extends ProcessorConfig {
  type: 'split';
  /** Field to split */
  field: string;
  /** Separator */
  separator: string;
  /** Target field (optional) */
  targetField?: string;
  /** Preserve trailing */
  preserveTrailing?: boolean;
}

/**
 * Join processor configuration
 */
export interface JoinProcessorConfig extends ProcessorConfig {
  type: 'join';
  /** Field to join */
  field: string;
  /** Separator */
  separator: string;
  /** Target field (optional) */
  targetField?: string;
}

/**
 * Date processor configuration
 */
export interface DateProcessorConfig extends ProcessorConfig {
  type: 'date';
  /** Field containing date */
  field: string;
  /** Date formats to try */
  formats: string[];
  /** Target field */
  targetField?: string;
  /** Timezone */
  timezone?: string;
}

/**
 * HTML strip processor configuration
 */
export interface HtmlStripProcessorConfig extends ProcessorConfig {
  type: 'html_strip';
  /** Field to strip HTML from */
  field: string;
  /** Target field (optional) */
  targetField?: string;
}

/**
 * JSON processor configuration
 */
export interface JsonProcessorConfig extends ProcessorConfig {
  type: 'json';
  /** Field containing JSON */
  field: string;
  /** Target field */
  targetField?: string;
  /** Add to root */
  addToRoot?: boolean;
}

/**
 * Pipeline processor configuration
 */
export interface PipelineProcessorConfig extends ProcessorConfig {
  type: 'pipeline';
  /** Pipeline name */
  name: string;
}

/**
 * Inference processor configuration
 */
export interface InferenceProcessorConfig extends ProcessorConfig {
  type: 'inference';
  /** Model ID */
  modelId: string;
  /** Input field */
  inputOutput?: Array<{
    inputField: string;
    outputField: string;
  }>;
  /** Target field for results */
  targetField?: string;
  /** Field map (legacy) */
  fieldMap?: Record<string, string>;
  /** Inference config */
  inferenceConfig?: Record<string, unknown>;
}

/**
 * Foreach processor configuration
 */
export interface ForeachProcessorConfig extends ProcessorConfig {
  type: 'foreach';
  /** Field containing array */
  field: string;
  /** Processor to apply */
  processor: ProcessorConfig;
}

/**
 * Any processor type
 */
export type AnyProcessorConfig =
  | SetProcessorConfig
  | RemoveProcessorConfig
  | RenameProcessorConfig
  | ScriptProcessorConfig
  | ConvertProcessorConfig
  | LowercaseProcessorConfig
  | UppercaseProcessorConfig
  | TrimProcessorConfig
  | SplitProcessorConfig
  | JoinProcessorConfig
  | DateProcessorConfig
  | HtmlStripProcessorConfig
  | JsonProcessorConfig
  | PipelineProcessorConfig
  | InferenceProcessorConfig
  | ForeachProcessorConfig
  | ProcessorConfig;

/**
 * Pipeline configuration
 */
export interface PipelineConfig {
  /** Pipeline description */
  description?: string;
  /** Processors */
  processors: AnyProcessorConfig[];
  /** On failure processors */
  onFailure?: AnyProcessorConfig[];
  /** Version */
  version?: number;
  /** Metadata */
  meta?: Record<string, unknown>;
}

// ============================================================================
// Ingest Pipeline Builder
// ============================================================================

/**
 * Fluent builder for ingest pipelines
 */
export class IngestPipelineBuilder {
  private description?: string;
  private processors: AnyProcessorConfig[] = [];
  private onFailureProcessors: AnyProcessorConfig[] = [];
  private pipelineVersion?: number;
  private pipelineMeta?: Record<string, unknown>;

  /**
   * Set pipeline description
   */
  describe(description: string): this {
    this.description = description;
    return this;
  }

  /**
   * Set pipeline version
   */
  version(version: number): this {
    this.pipelineVersion = version;
    return this;
  }

  /**
   * Set pipeline metadata
   */
  meta(meta: Record<string, unknown>): this {
    this.pipelineMeta = meta;
    return this;
  }

  // ============================================================================
  // Basic Processors
  // ============================================================================

  /**
   * Set a field value
   */
  set(field: string, value: unknown, options?: { override?: boolean; ignoreEmpty?: boolean }): this {
    this.processors.push({
      type: 'set',
      field,
      value,
      override: options?.override,
      ignoreEmptyValue: options?.ignoreEmpty,
    } as SetProcessorConfig);
    return this;
  }

  /**
   * Remove a field
   */
  remove(field: string | string[]): this {
    this.processors.push({
      type: 'remove',
      field,
    } as RemoveProcessorConfig);
    return this;
  }

  /**
   * Rename a field
   */
  rename(field: string, targetField: string): this {
    this.processors.push({
      type: 'rename',
      field,
      targetField,
    } as RenameProcessorConfig);
    return this;
  }

  /**
   * Execute a script
   */
  script(source: string, params?: Record<string, unknown>, lang?: string): this {
    this.processors.push({
      type: 'script',
      source,
      params,
      lang,
    } as ScriptProcessorConfig);
    return this;
  }

  /**
   * Convert field type
   */
  convert(field: string, targetType: ConvertProcessorConfig['targetType'], targetField?: string): this {
    this.processors.push({
      type: 'convert',
      field,
      targetType,
      targetField,
    } as ConvertProcessorConfig);
    return this;
  }

  // ============================================================================
  // String Processors
  // ============================================================================

  /**
   * Lowercase a field
   */
  lowercase(field: string, targetField?: string): this {
    this.processors.push({
      type: 'lowercase',
      field,
      targetField,
    } as LowercaseProcessorConfig);
    return this;
  }

  /**
   * Uppercase a field
   */
  uppercase(field: string, targetField?: string): this {
    this.processors.push({
      type: 'uppercase',
      field,
      targetField,
    } as UppercaseProcessorConfig);
    return this;
  }

  /**
   * Trim a field
   */
  trim(field: string, targetField?: string): this {
    this.processors.push({
      type: 'trim',
      field,
      targetField,
    } as TrimProcessorConfig);
    return this;
  }

  /**
   * Split a field
   */
  split(field: string, separator: string, targetField?: string): this {
    this.processors.push({
      type: 'split',
      field,
      separator,
      targetField,
    } as SplitProcessorConfig);
    return this;
  }

  /**
   * Join array field
   */
  join(field: string, separator: string, targetField?: string): this {
    this.processors.push({
      type: 'join',
      field,
      separator,
      targetField,
    } as JoinProcessorConfig);
    return this;
  }

  /**
   * Strip HTML tags
   */
  htmlStrip(field: string, targetField?: string): this {
    this.processors.push({
      type: 'html_strip',
      field,
      targetField,
    } as HtmlStripProcessorConfig);
    return this;
  }

  // ============================================================================
  // Data Processors
  // ============================================================================

  /**
   * Parse date field
   */
  date(field: string, formats: string[], options?: { targetField?: string; timezone?: string }): this {
    this.processors.push({
      type: 'date',
      field,
      formats,
      targetField: options?.targetField,
      timezone: options?.timezone,
    } as DateProcessorConfig);
    return this;
  }

  /**
   * Parse JSON field
   */
  json(field: string, options?: { targetField?: string; addToRoot?: boolean }): this {
    this.processors.push({
      type: 'json',
      field,
      targetField: options?.targetField,
      addToRoot: options?.addToRoot,
    } as JsonProcessorConfig);
    return this;
  }

  // ============================================================================
  // Advanced Processors
  // ============================================================================

  /**
   * Execute another pipeline
   */
  pipeline(name: string): this {
    this.processors.push({
      type: 'pipeline',
      name,
    } as PipelineProcessorConfig);
    return this;
  }

  /**
   * Apply processor to each element in array
   */
  foreach(field: string, processor: AnyProcessorConfig): this {
    this.processors.push({
      type: 'foreach',
      field,
      processor,
    } as ForeachProcessorConfig);
    return this;
  }

  /**
   * Run ML inference
   */
  inference(
    modelId: string,
    options?: {
      inputField?: string;
      outputField?: string;
      inputOutput?: Array<{ inputField: string; outputField: string }>;
      targetField?: string;
      inferenceConfig?: Record<string, unknown>;
    }
  ): this {
    const config: InferenceProcessorConfig = {
      type: 'inference',
      modelId,
      targetField: options?.targetField,
      inferenceConfig: options?.inferenceConfig,
    };

    if (options?.inputOutput) {
      config.inputOutput = options.inputOutput;
    } else if (options?.inputField && options?.outputField) {
      config.inputOutput = [{ inputField: options.inputField, outputField: options.outputField }];
    }

    this.processors.push(config);
    return this;
  }

  // ============================================================================
  // Conditional & Error Handling
  // ============================================================================

  /**
   * Add conditional processor
   */
  conditionalSet(condition: string, field: string, value: unknown): this {
    this.processors.push({
      type: 'set',
      field,
      value,
      if: condition,
    } as SetProcessorConfig);
    return this;
  }

  /**
   * Add processor with ignore failure
   */
  ignoreFailure(processor: AnyProcessorConfig): this {
    this.processors.push({
      ...processor,
      ignoreFailure: true,
    });
    return this;
  }

  /**
   * Add custom processor
   */
  addProcessor(processor: AnyProcessorConfig): this {
    this.processors.push(processor);
    return this;
  }

  /**
   * Add on-failure handler
   */
  onFailure(processor: AnyProcessorConfig): this {
    this.onFailureProcessors.push(processor);
    return this;
  }

  // ============================================================================
  // Build
  // ============================================================================

  /**
   * Build pipeline configuration
   */
  build(): PipelineConfig {
    return {
      description: this.description,
      processors: this.processors,
      onFailure: this.onFailureProcessors.length > 0 ? this.onFailureProcessors : undefined,
      version: this.pipelineVersion,
      meta: this.pipelineMeta,
    };
  }

  /**
   * Build Elasticsearch pipeline body
   */
  buildBody(): Record<string, unknown> {
    const body: Record<string, unknown> = {
      processors: this.processors.map((p) => this.processorToEsFormat(p)),
    };

    if (this.description) body.description = this.description;
    if (this.onFailureProcessors.length > 0) {
      body.on_failure = this.onFailureProcessors.map((p) => this.processorToEsFormat(p));
    }
    if (this.pipelineVersion) body.version = this.pipelineVersion;
    if (this.pipelineMeta) body._meta = this.pipelineMeta;

    return body;
  }

  /**
   * Convert processor config to ES format
   */
  private processorToEsFormat(processor: AnyProcessorConfig): Record<string, unknown> {
    const { type, tag, description, if: condition, ignoreFailure, onFailure, ...rest } = processor;
    
    const esProcessor: Record<string, unknown> = { ...rest };
    
    if (tag) esProcessor.tag = tag;
    if (description) esProcessor.description = description;
    if (condition) esProcessor.if = condition;
    if (ignoreFailure) esProcessor.ignore_failure = true;
    if (onFailure && onFailure.length > 0) {
      esProcessor.on_failure = onFailure.map((p) => this.processorToEsFormat(p));
    }

    // Convert camelCase to snake_case for specific fields
    if ('targetField' in esProcessor) {
      esProcessor.target_field = esProcessor.targetField;
      delete esProcessor.targetField;
    }
    if ('ignoreEmptyValue' in esProcessor) {
      esProcessor.ignore_empty_value = esProcessor.ignoreEmptyValue;
      delete esProcessor.ignoreEmptyValue;
    }
    if ('addToRoot' in esProcessor) {
      esProcessor.add_to_root = esProcessor.addToRoot;
      delete esProcessor.addToRoot;
    }
    if ('preserveTrailing' in esProcessor) {
      esProcessor.preserve_trailing = esProcessor.preserveTrailing;
      delete esProcessor.preserveTrailing;
    }
    if ('modelId' in esProcessor) {
      esProcessor.model_id = esProcessor.modelId;
      delete esProcessor.modelId;
    }
    if ('inputOutput' in esProcessor) {
      esProcessor.input_output = esProcessor.inputOutput;
      delete esProcessor.inputOutput;
    }
    if ('fieldMap' in esProcessor) {
      esProcessor.field_map = esProcessor.fieldMap;
      delete esProcessor.fieldMap;
    }
    if ('inferenceConfig' in esProcessor) {
      esProcessor.inference_config = esProcessor.inferenceConfig;
      delete esProcessor.inferenceConfig;
    }
    if ('targetType' in esProcessor) {
      esProcessor.target_type = esProcessor.targetType;
      delete esProcessor.targetType;
    }

    return { [type]: esProcessor };
  }
}

// ============================================================================
// Pipeline Manager
// ============================================================================

/**
 * Pipeline manager for CRUD operations
 */
export class PipelineManager {
  constructor(private readonly client: Client) {}

  /**
   * Create or update a pipeline
   */
  async put(name: string, pipeline: PipelineConfig | IngestPipelineBuilder): Promise<boolean> {
    const body = pipeline instanceof IngestPipelineBuilder
      ? pipeline.buildBody()
      : this.configToBody(pipeline);

    try {
      await this.client.ingest.putPipeline({
        id: name,
        body,
      } as Record<string, unknown>);
      return true;
    } catch (error) {
      throw wrapError(error, `Failed to create pipeline: ${name}`);
    }
  }

  /**
   * Get a pipeline
   */
  async get(name: string): Promise<PipelineConfig | undefined> {
    try {
      const response = await this.client.ingest.getPipeline({ id: name });
      const pipeline = response[name] as Record<string, unknown>;
      return pipeline ? this.bodyToConfig(pipeline) : undefined;
    } catch (error: unknown) {
      if ((error as { statusCode?: number }).statusCode === 404) {
        return undefined;
      }
      throw wrapError(error, `Failed to get pipeline: ${name}`);
    }
  }

  /**
   * Check if pipeline exists
   */
  async exists(name: string): Promise<boolean> {
    try {
      await this.client.ingest.getPipeline({ id: name });
      return true;
    } catch (error: unknown) {
      if ((error as { statusCode?: number }).statusCode === 404) {
        return false;
      }
      throw wrapError(error, `Failed to check pipeline: ${name}`);
    }
  }

  /**
   * Delete a pipeline
   */
  async delete(name: string): Promise<boolean> {
    try {
      await this.client.ingest.deletePipeline({ id: name });
      return true;
    } catch (error: unknown) {
      if ((error as { statusCode?: number }).statusCode === 404) {
        return false;
      }
      throw wrapError(error, `Failed to delete pipeline: ${name}`);
    }
  }

  /**
   * List all pipelines
   */
  async list(): Promise<Array<{ name: string; description?: string }>> {
    try {
      const response = await this.client.ingest.getPipeline();
      return Object.entries(response).map(([name, config]) => ({
        name,
        description: (config as Record<string, unknown>).description as string | undefined,
      }));
    } catch (error) {
      throw wrapError(error, 'Failed to list pipelines');
    }
  }

  /**
   * Simulate pipeline on documents
   */
  async simulate(
    name: string,
    docs: Array<Record<string, unknown>>
  ): Promise<Array<{ doc: Record<string, unknown>; error?: string }>> {
    try {
      const response = await this.client.ingest.simulate({
        id: name,
        body: {
          docs: docs.map((d) => ({ _source: d })),
        },
      } as Record<string, unknown>);

      return (response.docs as Array<Record<string, unknown>>).map((result) => {
        if (result.error) {
          return { doc: {}, error: JSON.stringify(result.error) };
        }
        const doc = (result.doc as Record<string, unknown>)?._source as Record<string, unknown>;
        return { doc: doc ?? {} };
      });
    } catch (error) {
      throw wrapError(error, 'Failed to simulate pipeline');
    }
  }

  /**
   * Convert config to ES body
   */
  private configToBody(config: PipelineConfig): Record<string, unknown> {
    const builder = new IngestPipelineBuilder();
    
    if (config.description) builder.describe(config.description);
    if (config.version) builder.version(config.version);
    if (config.meta) builder.meta(config.meta);
    
    for (const p of config.processors) {
      builder.addProcessor(p);
    }
    
    if (config.onFailure) {
      for (const p of config.onFailure) {
        builder.onFailure(p);
      }
    }

    return builder.buildBody();
  }

  /**
   * Convert ES body to config
   */
  private bodyToConfig(body: Record<string, unknown>): PipelineConfig {
    return {
      description: body.description as string | undefined,
      processors: (body.processors as Array<Record<string, unknown>>)?.map((p) => this.esFormatToProcessor(p)) ?? [],
      onFailure: (body.on_failure as Array<Record<string, unknown>>)?.map((p) => this.esFormatToProcessor(p)),
      version: body.version as number | undefined,
      meta: body._meta as Record<string, unknown> | undefined,
    };
  }

  /**
   * Convert ES format to processor config
   */
  private esFormatToProcessor(esProcessor: Record<string, unknown>): AnyProcessorConfig {
    const [type, config] = Object.entries(esProcessor)[0];
    const cfg = config as Record<string, unknown>;
    
    return {
      type,
      ...cfg,
      targetField: cfg.target_field as string,
    } as AnyProcessorConfig;
  }
}

// ============================================================================
// Preset Pipelines
// ============================================================================

/**
 * Preset pipeline configurations
 */
export const PipelinePresets = {
  /**
   * Basic text processing pipeline
   */
  textProcessing(): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe('Basic text processing pipeline')
      .trim('content')
      .htmlStrip('content', 'content_clean')
      .set('@timestamp', '{{_ingest.timestamp}}');
  },

  /**
   * Document metadata pipeline
   */
  documentMetadata(): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe('Document metadata extraction pipeline')
      .set('@timestamp', '{{_ingest.timestamp}}')
      .set('metadata.indexed_at', '{{_ingest.timestamp}}')
      .conditionalSet("ctx.metadata?.source == null", 'metadata.source', 'unknown');
  },

  /**
   * Embedding generation pipeline
   */
  embedding(modelId: string, sourceField: string = 'content', targetField: string = 'embedding'): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe(`Embedding generation pipeline using ${modelId}`)
      .inference(modelId, {
        inputField: sourceField,
        outputField: targetField,
        inferenceConfig: {
          text_embedding: {},
        },
      });
  },

  /**
   * ELSER sparse embedding pipeline
   */
  elserEmbedding(sourceField: string = 'content', targetField: string = 'ml.tokens'): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe('ELSER sparse embedding pipeline')
      .inference('.elser_model_2', {
        inputField: sourceField,
        outputField: targetField,
        inferenceConfig: {
          text_expansion: {
            results_field: 'tokens',
          },
        },
      });
  },

  /**
   * Combined preprocessing + embedding pipeline
   */
  ragDocument(modelId: string): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe('RAG document processing pipeline')
      // Preprocessing
      .set('@timestamp', '{{_ingest.timestamp}}')
      .trim('content')
      .htmlStrip('content', 'content_clean')
      // Generate embedding
      .inference(modelId, {
        inputField: 'content_clean',
        outputField: 'embedding',
        inferenceConfig: {
          text_embedding: {},
        },
      })
      // Cleanup
      .remove('content_clean');
  },

  /**
   * Chunked document pipeline
   */
  chunkedDocument(chunkField: string = 'chunks'): IngestPipelineBuilder {
    return new IngestPipelineBuilder()
      .describe('Chunked document processing pipeline')
      .set('@timestamp', '{{_ingest.timestamp}}')
      .foreach(chunkField, {
        type: 'set',
        field: '_ingest._value.processed',
        value: true,
      } as SetProcessorConfig);
  },
};

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a new ingest pipeline builder
 */
export function ingestPipeline(): IngestPipelineBuilder {
  return new IngestPipelineBuilder();
}

/**
 * Create a pipeline manager
 */
export function createPipelineManager(client: Client): PipelineManager {
  return new PipelineManager(client);
}