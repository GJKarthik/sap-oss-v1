/**
 * @sap-ai-sdk/elasticsearch - Boost Configuration
 *
 * Configurable boost weights for search tuning and optimization.
 */

// ============================================================================
// Types
// ============================================================================

/**
 * Field boost configuration
 */
export interface FieldBoost {
  /** Field name (supports nested: metadata.category) */
  field: string;
  /** Boost factor (default: 1.0) */
  boost: number;
  /** Whether to decay boost by field length */
  lengthNormalization?: boolean;
}

/**
 * Query boost configuration
 */
export interface QueryBoost {
  /** Boost for exact match queries */
  exactMatch?: number;
  /** Boost for phrase match queries */
  phraseMatch?: number;
  /** Boost for fuzzy match queries */
  fuzzyMatch?: number;
  /** Boost for prefix match queries */
  prefixMatch?: number;
  /** Boost for wildcard queries */
  wildcardMatch?: number;
}

/**
 * Temporal boost configuration
 */
export interface TemporalBoost {
  /** Field containing the date */
  dateField: string;
  /** Scale for decay (e.g., "7d", "30d", "1y") */
  scale: string;
  /** Offset before decay starts (e.g., "1d") */
  offset?: string;
  /** Decay factor (0-1, default: 0.5) */
  decay?: number;
  /** Origin date (default: now) */
  origin?: string | Date;
}

/**
 * Distance-based boost configuration (for geo fields)
 */
export interface DistanceBoost {
  /** Field containing geo_point */
  geoField: string;
  /** Origin point [lat, lon] */
  origin: [number, number];
  /** Scale for decay (e.g., "10km", "100mi") */
  scale: string;
  /** Offset before decay starts */
  offset?: string;
  /** Decay factor (0-1, default: 0.5) */
  decay?: number;
}

/**
 * Numeric boost configuration
 */
export interface NumericBoost {
  /** Field name */
  field: string;
  /** Origin value (optimal value) */
  origin: number;
  /** Scale for decay */
  scale: number;
  /** Offset before decay starts */
  offset?: number;
  /** Decay factor (0-1, default: 0.5) */
  decay?: number;
}

/**
 * Complete boost configuration
 */
export interface BoostConfig {
  /** Vector search boost (0-1, relative to text) */
  vectorBoost?: number;
  /** Text search boost (0-1, relative to vector) */
  textBoost?: number;
  /** Per-field boost configuration */
  fieldBoosts?: FieldBoost[];
  /** Query type boost configuration */
  queryBoosts?: QueryBoost;
  /** Temporal decay boost */
  temporalBoost?: TemporalBoost;
  /** Distance decay boost */
  distanceBoost?: DistanceBoost;
  /** Numeric decay boosts */
  numericBoosts?: NumericBoost[];
  /** Minimum boost (floor) */
  minBoost?: number;
  /** Maximum boost (ceiling) */
  maxBoost?: number;
}

/**
 * Boost function types
 */
export type BoostFunctionType = 'linear' | 'exp' | 'gauss';

/**
 * Decay function configuration
 */
export interface DecayFunction {
  /** Decay function type */
  type: BoostFunctionType;
  /** Field to apply decay to */
  field: string;
  /** Origin value */
  origin: unknown;
  /** Scale parameter */
  scale: string | number;
  /** Offset parameter */
  offset?: string | number;
  /** Decay factor */
  decay?: number;
}

// ============================================================================
// Boost Builder Class
// ============================================================================

/**
 * Fluent builder for boost configurations
 */
export class BoostBuilder {
  private config: BoostConfig = {};

  /**
   * Set vector search boost
   */
  vectorBoost(boost: number): this {
    if (boost < 0) throw new Error('Boost must be non-negative');
    this.config.vectorBoost = boost;
    return this;
  }

  /**
   * Set text search boost
   */
  textBoost(boost: number): this {
    if (boost < 0) throw new Error('Boost must be non-negative');
    this.config.textBoost = boost;
    return this;
  }

  /**
   * Set both vector and text boost (normalized to sum to 1)
   */
  ratio(vectorRatio: number, textRatio: number): this {
    const total = vectorRatio + textRatio;
    this.config.vectorBoost = vectorRatio / total;
    this.config.textBoost = textRatio / total;
    return this;
  }

  /**
   * Add field boost
   */
  field(field: string, boost: number, lengthNorm: boolean = false): this {
    if (!this.config.fieldBoosts) {
      this.config.fieldBoosts = [];
    }
    this.config.fieldBoosts.push({
      field,
      boost,
      lengthNormalization: lengthNorm,
    });
    return this;
  }

  /**
   * Set query type boosts
   */
  queryBoosts(boosts: QueryBoost): this {
    this.config.queryBoosts = boosts;
    return this;
  }

  /**
   * Add temporal (recency) boost
   */
  recency(dateField: string, scale: string, options: {
    offset?: string;
    decay?: number;
    origin?: string | Date;
  } = {}): this {
    this.config.temporalBoost = {
      dateField,
      scale,
      ...options,
    };
    return this;
  }

  /**
   * Add distance-based boost
   */
  distance(geoField: string, origin: [number, number], scale: string, options: {
    offset?: string;
    decay?: number;
  } = {}): this {
    this.config.distanceBoost = {
      geoField,
      origin,
      scale,
      ...options,
    };
    return this;
  }

  /**
   * Add numeric field boost
   */
  numeric(field: string, origin: number, scale: number, options: {
    offset?: number;
    decay?: number;
  } = {}): this {
    if (!this.config.numericBoosts) {
      this.config.numericBoosts = [];
    }
    this.config.numericBoosts.push({
      field,
      origin,
      scale,
      ...options,
    });
    return this;
  }

  /**
   * Set boost bounds
   */
  bounds(min: number, max: number): this {
    this.config.minBoost = min;
    this.config.maxBoost = max;
    return this;
  }

  /**
   * Build the configuration
   */
  build(): BoostConfig {
    return { ...this.config };
  }
}

/**
 * Create a boost builder
 */
export function boostBuilder(): BoostBuilder {
  return new BoostBuilder();
}

// ============================================================================
// Boost Presets
// ============================================================================

/**
 * Pre-configured boost settings for common use cases
 */
export const BoostPresets = {
  /**
   * Default balanced boost
   */
  balanced(): BoostConfig {
    return {
      vectorBoost: 0.5,
      textBoost: 0.5,
    };
  },

  /**
   * Semantic search focused (high vector weight)
   */
  semantic(): BoostConfig {
    return {
      vectorBoost: 0.8,
      textBoost: 0.2,
    };
  },

  /**
   * Keyword search focused (high text weight)
   */
  keyword(): BoostConfig {
    return {
      vectorBoost: 0.2,
      textBoost: 0.8,
    };
  },

  /**
   * Recency boost (favor recent documents)
   */
  recencyBiased(dateField: string = 'indexed_at', decayDays: number = 30): BoostConfig {
    return {
      vectorBoost: 0.5,
      textBoost: 0.5,
      temporalBoost: {
        dateField,
        scale: `${decayDays}d`,
        decay: 0.5,
      },
    };
  },

  /**
   * Title and content boost
   */
  titleContent(titleBoost: number = 2.0, contentBoost: number = 1.0): BoostConfig {
    return {
      vectorBoost: 0.5,
      textBoost: 0.5,
      fieldBoosts: [
        { field: 'title', boost: titleBoost },
        { field: 'content', boost: contentBoost },
      ],
    };
  },

  /**
   * Popularity boost (based on view/click count)
   */
  popularity(popularityField: string = 'view_count', maxViews: number = 10000): BoostConfig {
    return {
      vectorBoost: 0.5,
      textBoost: 0.5,
      numericBoosts: [
        {
          field: popularityField,
          origin: maxViews,
          scale: maxViews / 2,
          decay: 0.5,
        },
      ],
    };
  },

  /**
   * E-commerce product search
   */
  ecommerce(): BoostConfig {
    return {
      vectorBoost: 0.4,
      textBoost: 0.6,
      fieldBoosts: [
        { field: 'title', boost: 3.0 },
        { field: 'description', boost: 1.5 },
        { field: 'brand', boost: 2.0 },
        { field: 'category', boost: 1.5 },
      ],
      queryBoosts: {
        exactMatch: 3.0,
        phraseMatch: 2.0,
        fuzzyMatch: 0.8,
      },
    };
  },

  /**
   * Documentation/knowledge base search
   */
  documentation(): BoostConfig {
    return {
      vectorBoost: 0.6,
      textBoost: 0.4,
      fieldBoosts: [
        { field: 'title', boost: 2.5 },
        { field: 'content', boost: 1.0 },
        { field: 'headings', boost: 2.0 },
        { field: 'code', boost: 1.5 },
      ],
      temporalBoost: {
        dateField: 'updated_at',
        scale: '90d',
        decay: 0.8,
      },
    };
  },

  /**
   * News/articles search
   */
  news(): BoostConfig {
    return {
      vectorBoost: 0.4,
      textBoost: 0.6,
      fieldBoosts: [
        { field: 'headline', boost: 3.0 },
        { field: 'summary', boost: 2.0 },
        { field: 'body', boost: 1.0 },
      ],
      temporalBoost: {
        dateField: 'published_at',
        scale: '7d',
        decay: 0.3,
      },
    };
  },
};

// ============================================================================
// Boost Query Builders
// ============================================================================

/**
 * Build Elasticsearch function_score query from boost config
 */
export function buildFunctionScoreQuery(
  baseQuery: Record<string, unknown>,
  config: BoostConfig
): Record<string, unknown> {
  const functions: Array<Record<string, unknown>> = [];

  // Add temporal decay
  if (config.temporalBoost) {
    const { dateField, scale, offset, decay, origin } = config.temporalBoost;
    functions.push({
      gauss: {
        [dateField]: {
          origin: origin ?? 'now',
          scale,
          offset: offset ?? '0d',
          decay: decay ?? 0.5,
        },
      },
    });
  }

  // Add distance decay
  if (config.distanceBoost) {
    const { geoField, origin, scale, offset, decay } = config.distanceBoost;
    functions.push({
      gauss: {
        [geoField]: {
          origin,
          scale,
          offset: offset ?? '0km',
          decay: decay ?? 0.5,
        },
      },
    });
  }

  // Add numeric decays
  if (config.numericBoosts) {
    for (const numBoost of config.numericBoosts) {
      functions.push({
        gauss: {
          [numBoost.field]: {
            origin: numBoost.origin,
            scale: numBoost.scale,
            offset: numBoost.offset ?? 0,
            decay: numBoost.decay ?? 0.5,
          },
        },
      });
    }
  }

  // If no functions, return base query
  if (functions.length === 0) {
    return baseQuery;
  }

  const functionScore: Record<string, unknown> = {
    query: baseQuery,
    functions,
    score_mode: 'multiply',
    boost_mode: 'multiply',
  };

  // Add bounds if specified
  if (config.minBoost !== undefined) {
    functionScore.min_score = config.minBoost;
  }
  if (config.maxBoost !== undefined) {
    functionScore.max_boost = config.maxBoost;
  }

  return {
    function_score: functionScore,
  };
}

/**
 * Build field boost multi_match query
 */
export function buildBoostedMultiMatch(
  query: string,
  fieldBoosts: FieldBoost[],
  options: {
    type?: 'best_fields' | 'most_fields' | 'cross_fields' | 'phrase' | 'phrase_prefix';
    operator?: 'or' | 'and';
    fuzziness?: string | number;
    tieBreaker?: number;
  } = {}
): Record<string, unknown> {
  const fields = fieldBoosts.map((fb) =>
    fb.boost !== 1 ? `${fb.field}^${fb.boost}` : fb.field
  );

  return {
    multi_match: {
      query,
      fields,
      type: options.type ?? 'best_fields',
      operator: options.operator ?? 'or',
      fuzziness: options.fuzziness,
      tie_breaker: options.tieBreaker ?? 0.3,
    },
  };
}

/**
 * Build boosted bool query with query type boosts
 */
export function buildBoostedBoolQuery(
  query: string,
  field: string,
  queryBoosts: QueryBoost
): Record<string, unknown> {
  const should: Array<Record<string, unknown>> = [];

  // Exact match (term query on keyword field)
  if (queryBoosts.exactMatch) {
    should.push({
      term: {
        [`${field}.keyword`]: {
          value: query,
          boost: queryBoosts.exactMatch,
        },
      },
    });
  }

  // Phrase match
  if (queryBoosts.phraseMatch) {
    should.push({
      match_phrase: {
        [field]: {
          query,
          boost: queryBoosts.phraseMatch,
        },
      },
    });
  }

  // Fuzzy match
  if (queryBoosts.fuzzyMatch) {
    should.push({
      match: {
        [field]: {
          query,
          fuzziness: 'AUTO',
          boost: queryBoosts.fuzzyMatch,
        },
      },
    });
  }

  // Prefix match
  if (queryBoosts.prefixMatch) {
    should.push({
      prefix: {
        [field]: {
          value: query.toLowerCase(),
          boost: queryBoosts.prefixMatch,
        },
      },
    });
  }

  // Wildcard match (only if query contains wildcards)
  if (queryBoosts.wildcardMatch && (query.includes('*') || query.includes('?'))) {
    should.push({
      wildcard: {
        [field]: {
          value: query.toLowerCase(),
          boost: queryBoosts.wildcardMatch,
        },
      },
    });
  }

  return {
    bool: {
      should,
      minimum_should_match: 1,
    },
  };
}

// ============================================================================
// Boost Calculation Utilities
// ============================================================================

/**
 * Calculate decay value using gaussian function
 */
export function gaussianDecay(
  value: number,
  origin: number,
  scale: number,
  offset: number = 0,
  decay: number = 0.5
): number {
  const distance = Math.abs(value - origin);
  if (distance <= offset) {
    return 1;
  }
  const effectiveDistance = distance - offset;
  const sigma = scale / Math.sqrt(2 * Math.log(1 / decay));
  return Math.exp(-Math.pow(effectiveDistance, 2) / (2 * Math.pow(sigma, 2)));
}

/**
 * Calculate decay value using exponential function
 */
export function exponentialDecay(
  value: number,
  origin: number,
  scale: number,
  offset: number = 0,
  decay: number = 0.5
): number {
  const distance = Math.abs(value - origin);
  if (distance <= offset) {
    return 1;
  }
  const effectiveDistance = distance - offset;
  const lambda = Math.log(decay) / scale;
  return Math.exp(lambda * effectiveDistance);
}

/**
 * Calculate decay value using linear function
 */
export function linearDecay(
  value: number,
  origin: number,
  scale: number,
  offset: number = 0,
  decay: number = 0.5
): number {
  const distance = Math.abs(value - origin);
  if (distance <= offset) {
    return 1;
  }
  const effectiveDistance = distance - offset;
  const slope = (1 - decay) / scale;
  return Math.max(decay, 1 - slope * effectiveDistance);
}

/**
 * Calculate combined boost from multiple factors
 */
export function combineBoosts(
  boosts: number[],
  mode: 'multiply' | 'sum' | 'avg' | 'max' | 'min' = 'multiply'
): number {
  if (boosts.length === 0) return 1;

  switch (mode) {
    case 'multiply':
      return boosts.reduce((a, b) => a * b, 1);
    case 'sum':
      return boosts.reduce((a, b) => a + b, 0);
    case 'avg':
      return boosts.reduce((a, b) => a + b, 0) / boosts.length;
    case 'max':
      return Math.max(...boosts);
    case 'min':
      return Math.min(...boosts);
    default:
      return boosts.reduce((a, b) => a * b, 1);
  }
}

/**
 * Clamp boost value within bounds
 */
export function clampBoost(
  boost: number,
  min: number = 0,
  max: number = Infinity
): number {
  return Math.max(min, Math.min(max, boost));
}

// ============================================================================
// Dynamic Boost Adjustment
// ============================================================================

/**
 * Options for dynamic boost adjustment
 */
export interface DynamicBoostOptions {
  /** Target metric to optimize */
  targetMetric: 'precision' | 'recall' | 'f1' | 'ndcg' | 'mrr';
  /** Learning rate for adjustment */
  learningRate?: number;
  /** Minimum boost value */
  minBoost?: number;
  /** Maximum boost value */
  maxBoost?: number;
}

/**
 * Adjust boost based on search feedback
 */
export function adjustBoost(
  currentBoost: number,
  targetValue: number,
  actualValue: number,
  options: DynamicBoostOptions
): number {
  const { learningRate = 0.1, minBoost = 0, maxBoost = 2 } = options;

  // Calculate error
  const error = targetValue - actualValue;

  // Adjust boost proportionally to error
  const adjustment = error * learningRate;
  const newBoost = currentBoost + adjustment;

  return clampBoost(newBoost, minBoost, maxBoost);
}

/**
 * Auto-tune boosts based on relevance feedback
 */
export function autoTuneBoosts(
  config: BoostConfig,
  feedback: Array<{
    queryId: string;
    vectorScore: number;
    textScore: number;
    isRelevant: boolean;
  }>
): BoostConfig {
  // Group by query
  const byQuery = new Map<string, typeof feedback>();
  for (const item of feedback) {
    const existing = byQuery.get(item.queryId) || [];
    existing.push(item);
    byQuery.set(item.queryId, existing);
  }

  // Calculate average performance for each weight combination
  let bestVectorWeight = config.vectorBoost ?? 0.5;
  let bestF1 = 0;

  // Grid search
  for (let vw = 0; vw <= 1; vw += 0.05) {
    const tw = 1 - vw;
    
    let totalF1 = 0;
    let queryCount = 0;

    for (const items of byQuery.values()) {
      // Sort by combined score
      const sorted = [...items].sort((a, b) => {
        const scoreA = a.vectorScore * vw + a.textScore * tw;
        const scoreB = b.vectorScore * vw + b.textScore * tw;
        return scoreB - scoreA;
      });

      // Calculate precision, recall, F1 for top 10
      const topK = sorted.slice(0, 10);
      const relevantInTopK = topK.filter((x) => x.isRelevant).length;
      const totalRelevant = items.filter((x) => x.isRelevant).length;

      const precision = relevantInTopK / topK.length;
      const recall = totalRelevant > 0 ? relevantInTopK / totalRelevant : 0;
      const f1 = precision + recall > 0 
        ? (2 * precision * recall) / (precision + recall) 
        : 0;

      totalF1 += f1;
      queryCount++;
    }

    const avgF1 = queryCount > 0 ? totalF1 / queryCount : 0;
    if (avgF1 > bestF1) {
      bestF1 = avgF1;
      bestVectorWeight = vw;
    }
  }

  return {
    ...config,
    vectorBoost: bestVectorWeight,
    textBoost: 1 - bestVectorWeight,
  };
}