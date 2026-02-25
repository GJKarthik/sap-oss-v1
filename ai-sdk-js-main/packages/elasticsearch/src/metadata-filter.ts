/**
 * @sap-ai-sdk/elasticsearch - Metadata Filtering
 *
 * Comprehensive metadata filtering for Elasticsearch queries.
 */

// ============================================================================
// Types
// ============================================================================

/**
 * Filter operator types
 */
export type FilterOperator =
  | 'eq'      // Equal
  | 'ne'      // Not equal
  | 'gt'      // Greater than
  | 'gte'     // Greater than or equal
  | 'lt'      // Less than
  | 'lte'     // Less than or equal
  | 'in'      // In array
  | 'nin'     // Not in array
  | 'contains' // Contains (for text)
  | 'startsWith' // Starts with
  | 'endsWith'   // Ends with
  | 'exists'     // Field exists
  | 'missing'    // Field is missing
  | 'regex'      // Regular expression
  | 'range';     // Range filter

/**
 * Single filter condition
 */
export interface FilterCondition {
  /** Field path (supports dot notation for nested) */
  field: string;
  /** Filter operator */
  operator: FilterOperator;
  /** Value to compare against */
  value?: unknown;
  /** Second value (for range operator) */
  value2?: unknown;
  /** Case insensitive matching */
  caseInsensitive?: boolean;
}

/**
 * Logical combination of filters
 */
export interface FilterGroup {
  /** Logical operator */
  logic: 'and' | 'or' | 'not';
  /** Nested conditions or groups */
  conditions: Array<FilterCondition | FilterGroup>;
}

/**
 * Complete filter specification
 */
export type MetadataFilter = FilterCondition | FilterGroup;

/**
 * Prebuilt filter for common patterns
 */
export interface PrebuiltFilter {
  /** Filter name */
  name: string;
  /** Description */
  description: string;
  /** Build the filter query */
  build: (params?: Record<string, unknown>) => Record<string, unknown>;
}

// ============================================================================
// MetadataFilterBuilder Class
// ============================================================================

/**
 * Fluent builder for metadata filters
 */
export class MetadataFilterBuilder {
  private conditions: Array<FilterCondition | FilterGroup> = [];
  private metadataPrefix: string;
  private currentLogic: 'and' | 'or' = 'and';

  constructor(metadataPrefix: string = 'metadata') {
    this.metadataPrefix = metadataPrefix;
  }

  // ============================================================================
  // Comparison Operators
  // ============================================================================

  /**
   * Equal to
   */
  eq(field: string, value: unknown): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'eq',
      value,
    });
    return this;
  }

  /**
   * Not equal to
   */
  ne(field: string, value: unknown): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'ne',
      value,
    });
    return this;
  }

  /**
   * Greater than
   */
  gt(field: string, value: number | string | Date): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'gt',
      value: this.normalizeValue(value),
    });
    return this;
  }

  /**
   * Greater than or equal
   */
  gte(field: string, value: number | string | Date): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'gte',
      value: this.normalizeValue(value),
    });
    return this;
  }

  /**
   * Less than
   */
  lt(field: string, value: number | string | Date): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'lt',
      value: this.normalizeValue(value),
    });
    return this;
  }

  /**
   * Less than or equal
   */
  lte(field: string, value: number | string | Date): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'lte',
      value: this.normalizeValue(value),
    });
    return this;
  }

  /**
   * In array (match any)
   */
  in(field: string, values: unknown[]): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'in',
      value: values,
    });
    return this;
  }

  /**
   * Not in array
   */
  notIn(field: string, values: unknown[]): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'nin',
      value: values,
    });
    return this;
  }

  /**
   * Range filter (between)
   */
  between(field: string, min: number | string | Date, max: number | string | Date): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'range',
      value: this.normalizeValue(min),
      value2: this.normalizeValue(max),
    });
    return this;
  }

  // ============================================================================
  // String Operators
  // ============================================================================

  /**
   * Contains substring
   */
  contains(field: string, value: string, caseInsensitive: boolean = false): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'contains',
      value,
      caseInsensitive,
    });
    return this;
  }

  /**
   * Starts with
   */
  startsWith(field: string, value: string, caseInsensitive: boolean = false): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'startsWith',
      value,
      caseInsensitive,
    });
    return this;
  }

  /**
   * Ends with
   */
  endsWith(field: string, value: string, caseInsensitive: boolean = false): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'endsWith',
      value,
      caseInsensitive,
    });
    return this;
  }

  /**
   * Regex match
   */
  regex(field: string, pattern: string, flags?: string): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'regex',
      value: pattern,
      caseInsensitive: flags?.includes('i'),
    });
    return this;
  }

  // ============================================================================
  // Existence Operators
  // ============================================================================

  /**
   * Field exists
   */
  exists(field: string): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'exists',
    });
    return this;
  }

  /**
   * Field is missing (doesn't exist)
   */
  missing(field: string): this {
    this.conditions.push({
      field: this.prefixField(field),
      operator: 'missing',
    });
    return this;
  }

  // ============================================================================
  // Logical Operators
  // ============================================================================

  /**
   * Start an AND group
   */
  and(builderFn: (builder: MetadataFilterBuilder) => void): this {
    const subBuilder = new MetadataFilterBuilder(this.metadataPrefix);
    builderFn(subBuilder);
    this.conditions.push({
      logic: 'and',
      conditions: subBuilder.conditions,
    });
    return this;
  }

  /**
   * Start an OR group
   */
  or(builderFn: (builder: MetadataFilterBuilder) => void): this {
    const subBuilder = new MetadataFilterBuilder(this.metadataPrefix);
    builderFn(subBuilder);
    this.conditions.push({
      logic: 'or',
      conditions: subBuilder.conditions,
    });
    return this;
  }

  /**
   * Negate a condition or group
   */
  not(builderFn: (builder: MetadataFilterBuilder) => void): this {
    const subBuilder = new MetadataFilterBuilder(this.metadataPrefix);
    builderFn(subBuilder);
    this.conditions.push({
      logic: 'not',
      conditions: subBuilder.conditions,
    });
    return this;
  }

  // ============================================================================
  // Convenience Methods
  // ============================================================================

  /**
   * Filter by source/type
   */
  source(source: string): this {
    return this.eq('source', source);
  }

  /**
   * Filter by multiple sources
   */
  sources(...sources: string[]): this {
    return this.in('source', sources);
  }

  /**
   * Filter by category
   */
  category(category: string): this {
    return this.eq('category', category);
  }

  /**
   * Filter by tags (all must match)
   */
  tags(...tags: string[]): this {
    for (const tag of tags) {
      this.eq('tags', tag);
    }
    return this;
  }

  /**
   * Filter by any tag
   */
  anyTag(...tags: string[]): this {
    return this.or((b) => {
      for (const tag of tags) {
        b.eq('tags', tag);
      }
    });
  }

  /**
   * Filter by date range
   */
  dateRange(
    field: string,
    options: {
      from?: Date | string;
      to?: Date | string;
    }
  ): this {
    if (options.from) {
      this.gte(field, options.from);
    }
    if (options.to) {
      this.lte(field, options.to);
    }
    return this;
  }

  /**
   * Filter by created date range
   */
  createdBetween(from: Date | string, to: Date | string): this {
    return this.dateRange('created_at', { from, to });
  }

  /**
   * Filter by updated date range
   */
  updatedBetween(from: Date | string, to: Date | string): this {
    return this.dateRange('updated_at', { from, to });
  }

  /**
   * Filter by author
   */
  author(author: string): this {
    return this.eq('author', author);
  }

  /**
   * Filter by language
   */
  language(lang: string): this {
    return this.eq('language', lang);
  }

  /**
   * Filter published documents only
   */
  published(): this {
    return this.eq('status', 'published');
  }

  /**
   * Filter draft documents only
   */
  draft(): this {
    return this.eq('status', 'draft');
  }

  // ============================================================================
  // Build Methods
  // ============================================================================

  /**
   * Build Elasticsearch query filter
   */
  build(): Record<string, unknown> {
    if (this.conditions.length === 0) {
      return {};
    }

    if (this.conditions.length === 1) {
      return this.buildCondition(this.conditions[0]);
    }

    // Multiple conditions default to AND
    return {
      bool: {
        filter: this.conditions.map((c) => this.buildCondition(c)),
      },
    };
  }

  /**
   * Build a single condition or group
   */
  private buildCondition(
    condition: FilterCondition | FilterGroup
  ): Record<string, unknown> {
    if ('logic' in condition) {
      return this.buildGroup(condition);
    }
    return this.buildSingleCondition(condition);
  }

  /**
   * Build a filter group
   */
  private buildGroup(group: FilterGroup): Record<string, unknown> {
    const conditions = group.conditions.map((c) => this.buildCondition(c));

    switch (group.logic) {
      case 'and':
        return {
          bool: {
            filter: conditions,
          },
        };
      case 'or':
        return {
          bool: {
            should: conditions,
            minimum_should_match: 1,
          },
        };
      case 'not':
        return {
          bool: {
            must_not: conditions,
          },
        };
      default:
        return { bool: { filter: conditions } };
    }
  }

  /**
   * Build a single filter condition
   */
  private buildSingleCondition(condition: FilterCondition): Record<string, unknown> {
    const { field, operator, value, value2, caseInsensitive } = condition;

    switch (operator) {
      case 'eq':
        return { term: { [field]: value } };

      case 'ne':
        return { bool: { must_not: [{ term: { [field]: value } }] } };

      case 'gt':
        return { range: { [field]: { gt: value } } };

      case 'gte':
        return { range: { [field]: { gte: value } } };

      case 'lt':
        return { range: { [field]: { lt: value } } };

      case 'lte':
        return { range: { [field]: { lte: value } } };

      case 'in':
        return { terms: { [field]: value } };

      case 'nin':
        return { bool: { must_not: [{ terms: { [field]: value } }] } };

      case 'range':
        return { range: { [field]: { gte: value, lte: value2 } } };

      case 'contains':
        return {
          wildcard: {
            [field]: {
              value: `*${value}*`,
              case_insensitive: caseInsensitive,
            },
          },
        };

      case 'startsWith':
        return {
          prefix: {
            [field]: {
              value: String(value),
              case_insensitive: caseInsensitive,
            },
          },
        };

      case 'endsWith':
        return {
          wildcard: {
            [field]: {
              value: `*${value}`,
              case_insensitive: caseInsensitive,
            },
          },
        };

      case 'regex':
        return {
          regexp: {
            [field]: {
              value: String(value),
              case_insensitive: caseInsensitive,
            },
          },
        };

      case 'exists':
        return { exists: { field } };

      case 'missing':
        return { bool: { must_not: [{ exists: { field } }] } };

      default:
        return { term: { [field]: value } };
    }
  }

  /**
   * Prefix field with metadata path
   */
  private prefixField(field: string): string {
    if (field.startsWith(this.metadataPrefix + '.')) {
      return field;
    }
    return `${this.metadataPrefix}.${field}`;
  }

  /**
   * Normalize value (convert Date to ISO string)
   */
  private normalizeValue(value: unknown): unknown {
    if (value instanceof Date) {
      return value.toISOString();
    }
    return value;
  }

  /**
   * Get raw conditions for inspection
   */
  getConditions(): Array<FilterCondition | FilterGroup> {
    return [...this.conditions];
  }

  /**
   * Check if builder has any conditions
   */
  isEmpty(): boolean {
    return this.conditions.length === 0;
  }

  /**
   * Clear all conditions
   */
  clear(): this {
    this.conditions = [];
    return this;
  }

  /**
   * Clone the builder
   */
  clone(): MetadataFilterBuilder {
    const cloned = new MetadataFilterBuilder(this.metadataPrefix);
    cloned.conditions = JSON.parse(JSON.stringify(this.conditions));
    return cloned;
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a metadata filter builder
 */
export function metadataFilter(prefix: string = 'metadata'): MetadataFilterBuilder {
  return new MetadataFilterBuilder(prefix);
}

/**
 * Create filter from object notation
 */
export function fromObject(
  obj: Record<string, unknown>,
  prefix: string = 'metadata'
): MetadataFilterBuilder {
  const builder = new MetadataFilterBuilder(prefix);

  for (const [key, value] of Object.entries(obj)) {
    if (value === null || value === undefined) {
      continue;
    }

    if (Array.isArray(value)) {
      builder.in(key, value);
    } else if (typeof value === 'object') {
      const spec = value as Record<string, unknown>;
      
      if ('$eq' in spec) builder.eq(key, spec.$eq);
      if ('$ne' in spec) builder.ne(key, spec.$ne);
      if ('$gt' in spec) builder.gt(key, spec.$gt as number);
      if ('$gte' in spec) builder.gte(key, spec.$gte as number);
      if ('$lt' in spec) builder.lt(key, spec.$lt as number);
      if ('$lte' in spec) builder.lte(key, spec.$lte as number);
      if ('$in' in spec) builder.in(key, spec.$in as unknown[]);
      if ('$nin' in spec) builder.notIn(key, spec.$nin as unknown[]);
      if ('$contains' in spec) builder.contains(key, spec.$contains as string);
      if ('$startsWith' in spec) builder.startsWith(key, spec.$startsWith as string);
      if ('$endsWith' in spec) builder.endsWith(key, spec.$endsWith as string);
      if ('$exists' in spec && spec.$exists) builder.exists(key);
      if ('$missing' in spec && spec.$missing) builder.missing(key);
      if ('$regex' in spec) builder.regex(key, spec.$regex as string);
    } else {
      builder.eq(key, value);
    }
  }

  return builder;
}

// ============================================================================
// Filter Presets
// ============================================================================

/**
 * Common filter presets
 */
export const FilterPresets = {
  /**
   * Recent documents (last N days)
   */
  recent(days: number = 7, dateField: string = 'indexed_at'): MetadataFilterBuilder {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - days);
    return metadataFilter().gte(dateField, cutoff.toISOString());
  },

  /**
   * Documents from specific source
   */
  bySource(source: string): MetadataFilterBuilder {
    return metadataFilter().source(source);
  },

  /**
   * Documents with specific category
   */
  byCategory(category: string): MetadataFilterBuilder {
    return metadataFilter().category(category);
  },

  /**
   * Documents with all specified tags
   */
  withTags(...tags: string[]): MetadataFilterBuilder {
    return metadataFilter().tags(...tags);
  },

  /**
   * Documents with any of specified tags
   */
  withAnyTag(...tags: string[]): MetadataFilterBuilder {
    return metadataFilter().anyTag(...tags);
  },

  /**
   * Documents by author
   */
  byAuthor(author: string): MetadataFilterBuilder {
    return metadataFilter().author(author);
  },

  /**
   * Documents in date range
   */
  inDateRange(
    from: Date | string,
    to: Date | string,
    dateField: string = 'created_at'
  ): MetadataFilterBuilder {
    return metadataFilter().dateRange(dateField, { from, to });
  },

  /**
   * Published documents only
   */
  publishedOnly(): MetadataFilterBuilder {
    return metadataFilter().published();
  },

  /**
   * Documents by language
   */
  byLanguage(lang: string): MetadataFilterBuilder {
    return metadataFilter().language(lang);
  },

  /**
   * Documents with specific file type
   */
  byFileType(type: string): MetadataFilterBuilder {
    return metadataFilter().eq('file_type', type);
  },

  /**
   * Documents by content type
   */
  byContentType(contentType: string): MetadataFilterBuilder {
    return metadataFilter().eq('content_type', contentType);
  },

  /**
   * Documents in specific namespace/collection
   */
  inNamespace(namespace: string): MetadataFilterBuilder {
    return metadataFilter().eq('namespace', namespace);
  },

  /**
   * Documents with specific version
   */
  byVersion(version: string): MetadataFilterBuilder {
    return metadataFilter().eq('version', version);
  },

  /**
   * Documents modified after date
   */
  modifiedAfter(date: Date | string): MetadataFilterBuilder {
    return metadataFilter().gte('updated_at', date);
  },

  /**
   * Combine multiple filters with AND
   */
  combine(...builders: MetadataFilterBuilder[]): Record<string, unknown> {
    const filters = builders
      .filter((b) => !b.isEmpty())
      .map((b) => b.build());

    if (filters.length === 0) {
      return {};
    }

    if (filters.length === 1) {
      return filters[0];
    }

    return {
      bool: {
        filter: filters,
      },
    };
  },

  /**
   * Combine multiple filters with OR
   */
  combineOr(...builders: MetadataFilterBuilder[]): Record<string, unknown> {
    const filters = builders
      .filter((b) => !b.isEmpty())
      .map((b) => b.build());

    if (filters.length === 0) {
      return {};
    }

    if (filters.length === 1) {
      return filters[0];
    }

    return {
      bool: {
        should: filters,
        minimum_should_match: 1,
      },
    };
  },
};

// ============================================================================
// Query Helpers
// ============================================================================

/**
 * Merge filter into existing query
 */
export function mergeFilterIntoQuery(
  query: Record<string, unknown>,
  filter: Record<string, unknown>
): Record<string, unknown> {
  if (Object.keys(filter).length === 0) {
    return query;
  }

  if (Object.keys(query).length === 0) {
    return { bool: { filter: [filter] } };
  }

  // If query already has bool
  if (query.bool) {
    const boolQuery = query.bool as Record<string, unknown>;
    const existingFilter = boolQuery.filter as unknown[] | undefined;

    return {
      bool: {
        ...boolQuery,
        filter: existingFilter
          ? [...existingFilter, filter]
          : [filter],
      },
    };
  }

  // Wrap existing query in must
  return {
    bool: {
      must: [query],
      filter: [filter],
    },
  };
}

/**
 * Create filter from simple key-value pairs
 */
export function simpleFilter(
  pairs: Record<string, unknown>,
  prefix: string = 'metadata'
): Record<string, unknown> {
  return fromObject(pairs, prefix).build();
}

/**
 * Validate filter structure
 */
export function validateFilter(filter: MetadataFilter): boolean {
  if ('logic' in filter) {
    // Validate group
    if (!['and', 'or', 'not'].includes(filter.logic)) {
      return false;
    }
    return filter.conditions.every((c) => validateFilter(c));
  }

  // Validate condition
  if (!filter.field || typeof filter.field !== 'string') {
    return false;
  }

  if (!filter.operator) {
    return false;
  }

  const validOperators: FilterOperator[] = [
    'eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'in', 'nin',
    'contains', 'startsWith', 'endsWith', 'exists', 'missing',
    'regex', 'range',
  ];

  return validOperators.includes(filter.operator);
}