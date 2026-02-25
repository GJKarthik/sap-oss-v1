/**
 * SAP HANA Cloud Vector Store
 * 
 * Vector storage and similarity search using HANA Cloud Vector Engine
 */

import {
  type VectorDocument,
  type ScoredDocument,
  type VectorStoreConfig,
  type SearchOptions,
  type BatchOptions,
  type DistanceMetric,
  HANAError,
  HANAErrorCode,
  validateEmbedding,
  embeddingToVectorString,
  vectorStringToEmbedding,
  escapeIdentifier,
} from './types.js';
import { HANAClient } from './hana-client.js';

// ============================================================================
// HNSW Index Configuration
// ============================================================================

/**
 * HNSW Index configuration
 */
export interface HnswIndexConfig {
  /** Custom index name (auto-generated if not provided) */
  indexName?: string;
  
  /** Maximum neighbors per node (default: 16, range: 4-1000) */
  m?: number;
  
  /** Build-time candidate pool size (default: 200, range: 1-100000) */
  efConstruction?: number;
  
  /** Search-time candidate pool size (default: 100, range: 1-100000) */
  efSearch?: number;
  
  /** Similarity function (default: COSINE) */
  metric?: 'COSINE' | 'EUCLIDEAN';
}

/**
 * Internal embedding configuration for VECTOR_EMBEDDING function
 */
export interface InternalEmbeddingConfig {
  /** Embedding model ID */
  modelId: string;
  
  /** Remote source name (optional) */
  remoteSource?: string;
}

// ============================================================================
// HANA Vector Store
// ============================================================================

/**
 * HANA Cloud Vector Store
 * 
 * Provides vector storage and similarity search using HANA Cloud Vector Engine
 */
export class HANAVectorStore {
  private client: HANAClient;
  private config: Required<VectorStoreConfig>;
  private tableName: string;
  private initialized = false;

  constructor(client: HANAClient, config: VectorStoreConfig) {
    this.client = client;
    this.config = {
      tableName: config.tableName,
      schemaName: config.schemaName || '',
      embeddingDimensions: config.embeddingDimensions,
      idColumn: config.idColumn || 'ID',
      contentColumn: config.contentColumn || 'CONTENT',
      embeddingColumn: config.embeddingColumn || 'EMBEDDING',
      metadataColumn: config.metadataColumn || 'METADATA',
      vectorColumnType: config.vectorColumnType || 'REAL_VECTOR',
    };
    
    this.tableName = this.config.schemaName
      ? `${escapeIdentifier(this.config.schemaName)}.${escapeIdentifier(this.config.tableName)}`
      : escapeIdentifier(this.config.tableName);
  }

  // ==========================================================================
  // Schema Operations
  // ==========================================================================

  /**
   * Create the vector table if it doesn't exist
   */
  async createTable(): Promise<void> {
    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);
    const vectorType = this.config.vectorColumnType || 'REAL_VECTOR';

    const sql = `
      CREATE TABLE ${this.tableName} (
        ${idCol} NVARCHAR(255) PRIMARY KEY,
        ${contentCol} NCLOB,
        ${embeddingCol} ${vectorType}(${this.config.embeddingDimensions}),
        ${metadataCol} NCLOB,
        "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `;

    try {
      await this.client.execute(sql);
      this.initialized = true;
    } catch (error: any) {
      // Ignore if table already exists
      if (error.sqlCode !== 288) {
        throw error;
      }
      this.initialized = true;
    }
  }

  /**
   * Drop the vector table
   */
  async dropTable(): Promise<void> {
    await this.client.execute(`DROP TABLE ${this.tableName}`);
    this.initialized = false;
  }

  /**
   * Check if table exists
   */
  async tableExists(): Promise<boolean> {
    return this.client.tableExists(
      this.config.tableName,
      this.config.schemaName || undefined
    );
  }

  /**
   * Ensure table exists
   */
  async ensureTable(): Promise<void> {
    if (this.initialized) {
      return;
    }
    
    const exists = await this.tableExists();
    if (!exists) {
      await this.createTable();
    } else {
      this.initialized = true;
    }
  }

  // ==========================================================================
  // Document Operations
  // ==========================================================================

  /**
   * Add a single document
   */
  async add(document: VectorDocument): Promise<void> {
    await this.addMany([document]);
  }

  /**
   * Add multiple documents
   */
  async addMany(
    documents: VectorDocument[],
    options: BatchOptions = {}
  ): Promise<void> {
    if (documents.length === 0) {
      return;
    }

    await this.ensureTable();

    const batchSize = options.batchSize || 1000;
    const total = documents.length;
    let completed = 0;

    // Process in batches
    for (let i = 0; i < documents.length; i += batchSize) {
      const batch = documents.slice(i, i + batchSize);
      await this.insertBatch(batch);
      
      completed += batch.length;
      if (options.onProgress) {
        options.onProgress(completed, total);
      }
    }
  }

  /**
   * Insert a batch of documents
   */
  private async insertBatch(documents: VectorDocument[]): Promise<void> {
    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    const sql = `
      INSERT INTO ${this.tableName} 
        (${idCol}, ${contentCol}, ${embeddingCol}, ${metadataCol})
      VALUES (?, ?, TO_REAL_VECTOR(?), ?)
    `;

    const params = documents.map(doc => {
      validateEmbedding(doc.embedding, this.config.embeddingDimensions);
      return [
        doc.id,
        doc.content,
        embeddingToVectorString(doc.embedding),
        doc.metadata ? JSON.stringify(doc.metadata) : null,
      ];
    });

    await this.client.executeBatch(sql, params);
  }

  /**
   * Upsert documents (insert or update)
   */
  async upsert(
    documents: VectorDocument[],
    options: BatchOptions = {}
  ): Promise<void> {
    if (documents.length === 0) {
      return;
    }

    await this.ensureTable();

    const batchSize = options.batchSize || 1000;
    const total = documents.length;
    let completed = 0;

    // Process in batches
    for (let i = 0; i < documents.length; i += batchSize) {
      const batch = documents.slice(i, i + batchSize);
      await this.upsertBatch(batch);
      
      completed += batch.length;
      if (options.onProgress) {
        options.onProgress(completed, total);
      }
    }
  }

  /**
   * Upsert a batch of documents
   */
  private async upsertBatch(documents: VectorDocument[]): Promise<void> {
    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    // Use UPSERT (REPLACE in HANA)
    const sql = `
      UPSERT ${this.tableName} 
        (${idCol}, ${contentCol}, ${embeddingCol}, ${metadataCol}, "UPDATED_AT")
      VALUES (?, ?, TO_REAL_VECTOR(?), ?, CURRENT_TIMESTAMP)
      WITH PRIMARY KEY
    `;

    const params = documents.map(doc => {
      validateEmbedding(doc.embedding, this.config.embeddingDimensions);
      return [
        doc.id,
        doc.content,
        embeddingToVectorString(doc.embedding),
        doc.metadata ? JSON.stringify(doc.metadata) : null,
      ];
    });

    await this.client.executeBatch(sql, params);
  }

  /**
   * Delete documents by ID
   */
  async delete(ids: string[]): Promise<number> {
    if (ids.length === 0) {
      return 0;
    }

    const idCol = escapeIdentifier(this.config.idColumn);
    const placeholders = ids.map(() => '?').join(', ');
    const sql = `DELETE FROM ${this.tableName} WHERE ${idCol} IN (${placeholders})`;
    
    return this.client.execute(sql, ids);
  }

  /**
   * Delete all documents
   */
  async clear(): Promise<number> {
    return this.client.execute(`DELETE FROM ${this.tableName}`);
  }

  /**
   * Get a document by ID
   */
  async get(id: string): Promise<VectorDocument | null> {
    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    const sql = `
      SELECT 
        ${idCol} as "id",
        ${contentCol} as "content",
        ${embeddingCol} as "embedding",
        ${metadataCol} as "metadata"
      FROM ${this.tableName}
      WHERE ${idCol} = ?
    `;

    const results = await this.client.query<{
      id: string;
      content: string;
      embedding: string | Buffer;
      metadata: string | null;
    }>(sql, [id]);

    if (results.length === 0) {
      return null;
    }

    const row = results[0];
    return {
      id: row.id,
      content: row.content,
      embedding: vectorStringToEmbedding(row.embedding as string),
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
    };
  }

  /**
   * Get multiple documents by ID
   */
  async getMany(ids: string[]): Promise<VectorDocument[]> {
    if (ids.length === 0) {
      return [];
    }

    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    const placeholders = ids.map(() => '?').join(', ');
    const sql = `
      SELECT 
        ${idCol} as "id",
        ${contentCol} as "content",
        ${embeddingCol} as "embedding",
        ${metadataCol} as "metadata"
      FROM ${this.tableName}
      WHERE ${idCol} IN (${placeholders})
    `;

    const results = await this.client.query<{
      id: string;
      content: string;
      embedding: string | Buffer;
      metadata: string | null;
    }>(sql, ids);

    return results.map(row => ({
      id: row.id,
      content: row.content,
      embedding: vectorStringToEmbedding(row.embedding as string),
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
    }));
  }

  /**
   * Get document count
   */
  async count(): Promise<number> {
    const results = await this.client.query<{ CNT: number }>(
      `SELECT COUNT(*) as "CNT" FROM ${this.tableName}`
    );
    return results[0]?.CNT || 0;
  }

  // ==========================================================================
  // Similarity Search
  // ==========================================================================

  /**
   * Search for similar documents using COSINE_SIMILARITY
   */
  async similaritySearch(
    queryEmbedding: number[],
    options: SearchOptions = {}
  ): Promise<ScoredDocument[]> {
    validateEmbedding(queryEmbedding, this.config.embeddingDimensions);
    
    const k = options.k || 10;
    const minScore = options.minScore || 0;
    const metric = options.metric || 'COSINE';
    const includeEmbeddings = options.includeEmbeddings ?? false;

    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    // Build similarity function based on metric
    const similarityFunc = this.getSimilarityFunction(metric, embeddingCol);

    // Build embedding selection
    const embeddingSelect = includeEmbeddings 
      ? `, ${embeddingCol} as "embedding"` 
      : '';

    // Build filter clause
    const { filterClause, filterParams } = this.buildFilterClause(options.filter);

    const vectorString = embeddingToVectorString(queryEmbedding);
    
    const sql = `
      SELECT 
        ${idCol} as "id",
        ${contentCol} as "content",
        ${metadataCol} as "metadata"${embeddingSelect},
        ${similarityFunc} as "score"
      FROM ${this.tableName}
      WHERE ${similarityFunc} >= ?
      ${filterClause}
      ORDER BY "score" DESC
      LIMIT ?
    `;

    const params = [vectorString, minScore, ...filterParams, vectorString, k];

    // Note: We need to pass vectorString twice - once for WHERE, once for SELECT
    // This is a simplification; in production, use a subquery or CTE
    const actualSql = `
      SELECT 
        ${idCol} as "id",
        ${contentCol} as "content",
        ${metadataCol} as "metadata"${embeddingSelect},
        ${similarityFunc.replace('?', `'${vectorString}'`)} as "score"
      FROM ${this.tableName}
      WHERE ${similarityFunc.replace('?', `'${vectorString}'`)} >= ${minScore}
      ${filterClause}
      ORDER BY "score" DESC
      LIMIT ${k}
    `;

    const results = await this.client.query<{
      id: string;
      content: string;
      metadata: string | null;
      embedding?: string | Buffer;
      score: number;
    }>(actualSql, filterParams);

    return results.map(row => ({
      id: row.id,
      content: row.content,
      embedding: includeEmbeddings && row.embedding 
        ? vectorStringToEmbedding(row.embedding as string)
        : [],
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
      score: row.score,
    }));
  }

  /**
   * Search with text query (requires embedding function)
   */
  async similaritySearchWithScore(
    queryEmbedding: number[],
    k: number = 10
  ): Promise<Array<[VectorDocument, number]>> {
    const results = await this.similaritySearch(queryEmbedding, { k });
    return results.map(doc => [
      {
        id: doc.id,
        content: doc.content,
        embedding: doc.embedding,
        metadata: doc.metadata,
      },
      doc.score,
    ]);
  }

  /**
   * Maximum Marginal Relevance search
   * Balances relevance with diversity
   */
  async maxMarginalRelevanceSearch(
    queryEmbedding: number[],
    options: SearchOptions & { lambda?: number; fetchK?: number } = {}
  ): Promise<ScoredDocument[]> {
    const k = options.k || 10;
    const lambda = options.lambda || 0.5;
    const fetchK = options.fetchK || k * 4;

    // First, fetch more candidates
    const candidates = await this.similaritySearch(queryEmbedding, {
      ...options,
      k: fetchK,
      includeEmbeddings: true,
    });

    if (candidates.length === 0) {
      return [];
    }

    // Apply MMR algorithm
    const selected: ScoredDocument[] = [];
    const remaining = [...candidates];

    while (selected.length < k && remaining.length > 0) {
      let bestScore = -Infinity;
      let bestIdx = 0;

      for (let i = 0; i < remaining.length; i++) {
        const candidate = remaining[i];
        
        // Relevance score (similarity to query)
        const relevance = candidate.score;
        
        // Diversity score (max similarity to already selected)
        let maxSimilarity = 0;
        for (const s of selected) {
          const sim = this.cosineSimilarity(candidate.embedding, s.embedding);
          if (sim > maxSimilarity) {
            maxSimilarity = sim;
          }
        }
        
        // MMR score
        const mmrScore = lambda * relevance - (1 - lambda) * maxSimilarity;
        
        if (mmrScore > bestScore) {
          bestScore = mmrScore;
          bestIdx = i;
        }
      }

      selected.push(remaining[bestIdx]);
      remaining.splice(bestIdx, 1);
    }

    return selected;
  }

  // ==========================================================================
  // Hybrid Search
  // ==========================================================================

  /**
   * Hybrid search combining vector similarity with keyword search
   */
  async hybridSearch(
    queryEmbedding: number[],
    keywords: string[],
    options: SearchOptions & { 
      vectorWeight?: number;
      keywordWeight?: number;
    } = {}
  ): Promise<ScoredDocument[]> {
    const k = options.k || 10;
    const vectorWeight = options.vectorWeight ?? 0.7;
    const keywordWeight = options.keywordWeight ?? 0.3;

    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    
    // Build keyword conditions
    const keywordConditions = keywords
      .map(() => `CONTAINS(${contentCol}, ?)`)
      .join(' OR ');

    const vectorString = embeddingToVectorString(queryEmbedding);
    
    const sql = `
      SELECT 
        ${escapeIdentifier(this.config.idColumn)} as "id",
        ${contentCol} as "content",
        ${escapeIdentifier(this.config.metadataColumn)} as "metadata",
        (
          ${vectorWeight} * COSINE_SIMILARITY(${embeddingCol}, TO_REAL_VECTOR('${vectorString}')) +
          ${keywordWeight} * CASE WHEN (${keywordConditions}) THEN 1.0 ELSE 0.0 END
        ) as "score"
      FROM ${this.tableName}
      WHERE COSINE_SIMILARITY(${embeddingCol}, TO_REAL_VECTOR('${vectorString}')) >= ${options.minScore || 0}
         OR (${keywordConditions})
      ORDER BY "score" DESC
      LIMIT ${k}
    `;

    const results = await this.client.query<{
      id: string;
      content: string;
      metadata: string | null;
      score: number;
    }>(sql, [...keywords, ...keywords]);

    return results.map(row => ({
      id: row.id,
      content: row.content,
      embedding: [],
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
      score: row.score,
    }));
  }

  // ==========================================================================
  // Private Helpers
  // ==========================================================================

  /**
   * Get similarity function SQL based on metric
   */
  private getSimilarityFunction(metric: DistanceMetric, embeddingCol: string): string {
    switch (metric) {
      case 'COSINE':
        return `COSINE_SIMILARITY(${embeddingCol}, TO_REAL_VECTOR(?))`;
      case 'EUCLIDEAN':
        // Convert distance to similarity: 1 / (1 + distance)
        return `(1.0 / (1.0 + L2DISTANCE(${embeddingCol}, TO_REAL_VECTOR(?))))`;
      case 'DOT_PRODUCT':
        return `DOT_PRODUCT(${embeddingCol}, TO_REAL_VECTOR(?))`;
      default:
        return `COSINE_SIMILARITY(${embeddingCol}, TO_REAL_VECTOR(?))`;
    }
  }

  /**
   * Build filter clause from metadata filter
   */
  private buildFilterClause(filter?: Record<string, unknown>): { 
    filterClause: string; 
    filterParams: unknown[];
  } {
    if (!filter || Object.keys(filter).length === 0) {
      return { filterClause: '', filterParams: [] };
    }

    const metadataCol = escapeIdentifier(this.config.metadataColumn);
    const conditions: string[] = [];
    const params: unknown[] = [];

    for (const [key, value] of Object.entries(filter)) {
      // Use JSON_VALUE for metadata filtering
      conditions.push(`JSON_VALUE(${metadataCol}, '$.${key}') = ?`);
      params.push(String(value));
    }

    return {
      filterClause: `AND ${conditions.join(' AND ')}`,
      filterParams: params,
    };
  }

  // ==========================================================================
  // HNSW Index Operations
  // ==========================================================================

  /**
   * Create an HNSW index for fast approximate nearest neighbor search
   * 
   * @param config - HNSW index configuration
   */
  async createHnswIndex(config: HnswIndexConfig = {}): Promise<void> {
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metric = config.metric || 'COSINE';
    const distanceFunc = metric === 'COSINE' ? 'COSINE_SIMILARITY' : 'L2DISTANCE';
    
    // Generate default index name
    const defaultIndexName = `${this.config.tableName}_${distanceFunc}_idx`;
    const indexName = config.indexName || defaultIndexName;
    
    // Validate parameters
    if (config.m !== undefined && (config.m < 4 || config.m > 1000)) {
      throw new HANAError(
        'M must be in the range [4, 1000]',
        HANAErrorCode.INVALID_INPUT
      );
    }
    
    if (config.efConstruction !== undefined && (config.efConstruction < 1 || config.efConstruction > 100000)) {
      throw new HANAError(
        'efConstruction must be in the range [1, 100000]',
        HANAErrorCode.INVALID_INPUT
      );
    }
    
    if (config.efSearch !== undefined && (config.efSearch < 1 || config.efSearch > 100000)) {
      throw new HANAError(
        'efSearch must be in the range [1, 100000]',
        HANAErrorCode.INVALID_INPUT
      );
    }
    
    // Build configuration JSON
    const buildConfig: Record<string, number> = {};
    const searchConfig: Record<string, number> = {};
    
    if (config.m !== undefined) buildConfig.M = config.m;
    if (config.efConstruction !== undefined) buildConfig.efConstruction = config.efConstruction;
    if (config.efSearch !== undefined) searchConfig.efSearch = config.efSearch;
    
    // Build SQL
    let sql = `
      CREATE HNSW VECTOR INDEX ${escapeIdentifier(indexName)} 
      ON ${this.tableName} (${embeddingCol})
      SIMILARITY FUNCTION ${distanceFunc}
    `;
    
    if (Object.keys(buildConfig).length > 0) {
      sql += ` BUILD CONFIGURATION '${JSON.stringify(buildConfig)}'`;
    }
    
    if (Object.keys(searchConfig).length > 0) {
      sql += ` SEARCH CONFIGURATION '${JSON.stringify(searchConfig)}'`;
    }
    
    sql += ' ONLINE';
    
    await this.client.execute(sql);
  }

  /**
   * Drop an HNSW index
   * 
   * @param indexName - Name of the index to drop
   */
  async dropHnswIndex(indexName: string): Promise<void> {
    await this.client.execute(`DROP INDEX ${escapeIdentifier(indexName)}`);
  }

  // ==========================================================================
  // Internal Embeddings (VECTOR_EMBEDDING function)
  // ==========================================================================

  /**
   * Generate embedding using HANA's internal VECTOR_EMBEDDING function
   * 
   * @param text - Text to embed
   * @param type - Embedding type: 'QUERY' or 'DOCUMENT'
   * @param config - Internal embedding configuration
   * @returns Embedding vector
   */
  async generateEmbedding(
    text: string,
    type: 'QUERY' | 'DOCUMENT',
    config: InternalEmbeddingConfig
  ): Promise<number[]> {
    const remoteSourceClause = config.remoteSource 
      ? `, "${config.remoteSource}"` 
      : '';
    
    const sql = `
      SELECT VECTOR_EMBEDDING(?, '${type}', ?${remoteSourceClause}) AS embedding
      FROM SYS.DUMMY
    `;
    
    const results = await this.client.query<{ embedding: string }>(
      sql,
      [text, config.modelId]
    );
    
    if (results.length === 0 || !results[0].embedding) {
      throw new HANAError(
        'No embedding returned from VECTOR_EMBEDDING function',
        HANAErrorCode.QUERY_FAILED
      );
    }
    
    return vectorStringToEmbedding(results[0].embedding);
  }

  /**
   * Add texts using internal embeddings (VECTOR_EMBEDDING function)
   * 
   * @param texts - Array of { id, content, metadata } to add
   * @param config - Internal embedding configuration
   * @param options - Batch options
   */
  async addTextsWithInternalEmbedding(
    texts: Array<{ id: string; content: string; metadata?: Record<string, unknown> }>,
    config: InternalEmbeddingConfig,
    options: BatchOptions = {}
  ): Promise<void> {
    if (texts.length === 0) {
      return;
    }

    await this.ensureTable();

    const batchSize = options.batchSize || 100; // Smaller batch for internal embeddings
    const total = texts.length;
    let completed = 0;

    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    const remoteSourceClause = config.remoteSource 
      ? `, "${config.remoteSource}"` 
      : '';

    const sql = `
      INSERT INTO ${this.tableName} 
        (${idCol}, ${contentCol}, ${embeddingCol}, ${metadataCol})
      VALUES (?, ?, VECTOR_EMBEDDING(?, 'DOCUMENT', ?${remoteSourceClause}), ?)
    `;

    for (let i = 0; i < texts.length; i += batchSize) {
      const batch = texts.slice(i, i + batchSize);
      
      const params = batch.map(item => [
        item.id,
        item.content,
        item.content, // Text to embed
        config.modelId,
        item.metadata ? JSON.stringify(item.metadata) : null,
      ]);

      await this.client.executeBatch(sql, params);
      
      completed += batch.length;
      if (options.onProgress) {
        options.onProgress(completed, total);
      }
    }
  }

  /**
   * Similarity search using internal embeddings
   * 
   * @param queryText - Text to search for
   * @param config - Internal embedding configuration
   * @param options - Search options
   * @returns Scored documents
   */
  async similaritySearchWithInternalEmbedding(
    queryText: string,
    config: InternalEmbeddingConfig,
    options: SearchOptions = {}
  ): Promise<ScoredDocument[]> {
    const k = options.k || 10;
    const minScore = options.minScore || 0;
    const includeEmbeddings = options.includeEmbeddings ?? false;

    const idCol = escapeIdentifier(this.config.idColumn);
    const contentCol = escapeIdentifier(this.config.contentColumn);
    const embeddingCol = escapeIdentifier(this.config.embeddingColumn);
    const metadataCol = escapeIdentifier(this.config.metadataColumn);

    const embeddingSelect = includeEmbeddings 
      ? `, ${embeddingCol} as "embedding"` 
      : '';

    const { filterClause, filterParams } = this.buildFilterClause(options.filter);

    const remoteSourceClause = config.remoteSource 
      ? `, "${config.remoteSource}"` 
      : '';

    const sql = `
      SELECT 
        ${idCol} as "id",
        ${contentCol} as "content",
        ${metadataCol} as "metadata"${embeddingSelect},
        COSINE_SIMILARITY(${embeddingCol}, VECTOR_EMBEDDING(?, 'QUERY', ?${remoteSourceClause})) as "score"
      FROM ${this.tableName}
      WHERE COSINE_SIMILARITY(${embeddingCol}, VECTOR_EMBEDDING(?, 'QUERY', ?${remoteSourceClause})) >= ?
      ${filterClause}
      ORDER BY "score" DESC
      LIMIT ?
    `;

    const params = [
      queryText, config.modelId,
      queryText, config.modelId,
      minScore,
      ...filterParams,
      k
    ];

    const results = await this.client.query<{
      id: string;
      content: string;
      metadata: string | null;
      embedding?: string;
      score: number;
    }>(sql, params);

    return results.map(row => ({
      id: row.id,
      content: row.content,
      embedding: includeEmbeddings && row.embedding 
        ? vectorStringToEmbedding(row.embedding)
        : [],
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
      score: row.score,
    }));
  }

  /**
   * Validate that internal embedding function is available
   * 
   * @param config - Internal embedding configuration
   */
  async validateInternalEmbedding(config: InternalEmbeddingConfig): Promise<boolean> {
    try {
      const remoteSourceClause = config.remoteSource 
        ? `, "${config.remoteSource}"` 
        : '';
      
      const sql = `
        SELECT COUNT(TO_NVARCHAR(
          VECTOR_EMBEDDING('test', 'QUERY', ?${remoteSourceClause})
        )) AS "CNT" 
        FROM SYS.DUMMY
      `;
      
      await this.client.query(sql, [config.modelId]);
      return true;
    } catch {
      return false;
    }
  }

  // ==========================================================================
  // Private Helpers
  // ==========================================================================

  /**
   * Calculate cosine similarity between two vectors
   */
  private cosineSimilarity(a: number[], b: number[]): number {
    if (a.length !== b.length) {
      return 0;
    }

    let dotProduct = 0;
    let normA = 0;
    let normB = 0;

    for (let i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA === 0 || normB === 0) {
      return 0;
    }

    return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a HANA Vector Store
 */
export function createHANAVectorStore(
  client: HANAClient,
  config: VectorStoreConfig
): HANAVectorStore {
  return new HANAVectorStore(client, config);
}