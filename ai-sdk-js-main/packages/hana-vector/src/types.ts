// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP HANA Cloud Vector Engine Types
 * 
 * Configuration and data types for HANA Cloud vector operations
 */

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * HANA Cloud connection configuration
 */
export interface HANAConfig {
  /** HANA Cloud host */
  host: string;
  
  /** HANA Cloud port (default: 443) */
  port?: number;
  
  /** Database user */
  user: string;
  
  /** Database password */
  password: string;
  
  /** Default schema */
  schema?: string;
  
  /** Enable TLS encryption (default: true) */
  encrypt?: boolean;
  
  /** Validate SSL certificate (default: true) */
  sslValidateCertificate?: boolean;
  
  /** Connection timeout in milliseconds */
  connectTimeout?: number;
  
  /** Query timeout in milliseconds */
  commandTimeout?: number;
  
  /** Current schema to use */
  currentSchema?: string;
  
  /** Application name for tracking */
  applicationName?: string;
}

/**
 * HANA Cloud service binding (from VCAP_SERVICES)
 */
export interface HANAServiceBinding {
  host: string;
  port: string;
  user: string;
  password: string;
  schema?: string;
  certificate?: string;
  driver?: string;
  hdi_user?: string;
  hdi_password?: string;
}

/**
 * Connection pool configuration
 */
export interface PoolConfig {
  /** Minimum connections (default: 1) */
  min?: number;
  
  /** Maximum connections (default: 10) */
  max?: number;
  
  /** Acquire timeout in ms (default: 30000) */
  acquireTimeout?: number;
  
  /** Idle timeout in ms (default: 60000) */
  idleTimeout?: number;
  
  /** Eviction interval in ms (default: 30000) */
  evictionRunIntervalMillis?: number;
  
  /** Retry attempts for acquiring connection */
  acquireRetryAttempts?: number;
}

// ============================================================================
// Vector Types
// ============================================================================

/**
 * Vector document for storage and retrieval
 */
export interface VectorDocument {
  /** Unique document ID */
  id: string;
  
  /** Document content (text) */
  content: string;
  
  /** Embedding vector */
  embedding: number[];
  
  /** Optional metadata */
  metadata?: Record<string, unknown>;
}

/**
 * Document with similarity score (search result)
 */
export interface ScoredDocument extends VectorDocument {
  /** Similarity score (0-1 for cosine) */
  score: number;
}

/**
 * Supported vector column types
 */
export type VectorColumnType = 'REAL_VECTOR' | 'HALF_VECTOR';

/**
 * Vector store configuration
 */
export interface VectorStoreConfig {
  /** Table name for vector storage */
  tableName: string;
  
  /** Schema name (optional, uses connection default) */
  schemaName?: string;
  
  /** Embedding dimensions */
  embeddingDimensions: number;
  
  /** ID column name (default: "ID") */
  idColumn?: string;
  
  /** Content column name (default: "CONTENT") */
  contentColumn?: string;
  
  /** Embedding column name (default: "EMBEDDING") */
  embeddingColumn?: string;
  
  /** Metadata column name (default: "METADATA") */
  metadataColumn?: string;
  
  /** Vector column type (default: "REAL_VECTOR") */
  vectorColumnType?: VectorColumnType;
}

/**
 * Search options for similarity search
 */
export interface SearchOptions {
  /** Number of results to return (default: 10) */
  k?: number;
  
  /** Minimum similarity score (0-1, default: 0) */
  minScore?: number;
  
  /** Metadata filter (JSON conditions) */
  filter?: Record<string, unknown>;
  
  /** Include embeddings in results */
  includeEmbeddings?: boolean;
  
  /** Distance metric override */
  metric?: DistanceMetric;
}

/**
 * Supported distance metrics
 */
export type DistanceMetric = 'COSINE' | 'EUCLIDEAN' | 'DOT_PRODUCT';

// ============================================================================
// Table Definition Types
// ============================================================================

/**
 * Column definition for table creation
 */
export interface ColumnDefinition {
  name: string;
  type: string;
  nullable?: boolean;
  defaultValue?: string;
  primaryKey?: boolean;
}

/**
 * Table definition
 */
export interface TableDefinition {
  name: string;
  schema?: string;
  columns: ColumnDefinition[];
  primaryKey?: string[];
}

// ============================================================================
// Query Types
// ============================================================================

/**
 * Query result with metadata
 */
export interface QueryResult<T = Record<string, unknown>> {
  /** Result rows */
  rows: T[];
  
  /** Number of rows affected (for DML) */
  rowsAffected?: number;
  
  /** Column metadata */
  columns?: ColumnMetadata[];
  
  /** Execution time in ms */
  executionTime?: number;
}

/**
 * Column metadata
 */
export interface ColumnMetadata {
  name: string;
  type: string;
  nullable: boolean;
  length?: number;
  precision?: number;
  scale?: number;
}

/**
 * Batch operation options
 */
export interface BatchOptions {
  /** Batch size (default: 1000) */
  batchSize?: number;
  
  /** Parallel execution */
  parallel?: boolean;
  
  /** Progress callback */
  onProgress?: (completed: number, total: number) => void;
}

// ============================================================================
// Error Types
// ============================================================================

/**
 * HANA error codes
 */
export enum HANAErrorCode {
  /** Connection failed */
  CONNECTION_FAILED = 'CONNECTION_FAILED',
  
  /** Authentication failed */
  AUTH_FAILED = 'AUTH_FAILED',
  
  /** Query execution failed */
  QUERY_FAILED = 'QUERY_FAILED',
  
  /** Table not found */
  TABLE_NOT_FOUND = 'TABLE_NOT_FOUND',
  
  /** Column not found */
  COLUMN_NOT_FOUND = 'COLUMN_NOT_FOUND',
  
  /** Constraint violation */
  CONSTRAINT_VIOLATION = 'CONSTRAINT_VIOLATION',
  
  /** Duplicate key */
  DUPLICATE_KEY = 'DUPLICATE_KEY',
  
  /** Timeout */
  TIMEOUT = 'TIMEOUT',
  
  /** Invalid input */
  INVALID_INPUT = 'INVALID_INPUT',
  
  /** Pool exhausted */
  POOL_EXHAUSTED = 'POOL_EXHAUSTED',
  
  /** Unknown error */
  UNKNOWN = 'UNKNOWN',
}

/**
 * HANA error
 */
export class HANAError extends Error {
  constructor(
    message: string,
    public readonly code: HANAErrorCode,
    public readonly sqlCode?: number,
    public readonly sqlState?: string,
    public readonly cause?: Error
  ) {
    super(message);
    this.name = 'HANAError';
    
    // Maintain proper stack trace for V8
    if (typeof Error.captureStackTrace === 'function') {
      Error.captureStackTrace(this, HANAError);
    }
  }

  toJSON() {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      sqlCode: this.sqlCode,
      sqlState: this.sqlState,
    };
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Parse HANA service binding from environment
 */
export function parseBinding(binding: HANAServiceBinding): HANAConfig {
  return {
    host: binding.host,
    port: parseInt(binding.port, 10) || 443,
    user: binding.user,
    password: binding.password,
    schema: binding.schema,
    encrypt: true,
    sslValidateCertificate: true,
  };
}

/**
 * Get HANA config from VCAP_SERVICES
 */
export function getConfigFromVcap(): HANAConfig | undefined {
  const vcapServices = process.env.VCAP_SERVICES;
  if (!vcapServices) {
    return undefined;
  }
  
  try {
    const services = JSON.parse(vcapServices);
    
    // Try different service names
    const hanaService = 
      services.hana?.[0]?.credentials ||
      services['hana-cloud']?.[0]?.credentials ||
      services['hanatrial']?.[0]?.credentials;
    
    if (!hanaService) {
      return undefined;
    }
    
    return parseBinding(hanaService);
  } catch {
    return undefined;
  }
}

/**
 * Build connection string from config
 */
export function buildConnectionString(config: HANAConfig): string {
  const parts: string[] = [
    `serverNode=${config.host}:${config.port || 443}`,
    `uid=${config.user}`,
    `pwd=${config.password}`,
    `encrypt=${config.encrypt !== false}`,
  ];
  
  if (config.sslValidateCertificate !== undefined) {
    parts.push(`sslValidateCertificate=${config.sslValidateCertificate}`);
  }
  
  if (config.currentSchema) {
    parts.push(`currentSchema=${config.currentSchema}`);
  }
  
  if (config.connectTimeout) {
    parts.push(`connectTimeout=${config.connectTimeout}`);
  }
  
  if (config.commandTimeout) {
    parts.push(`commandTimeout=${config.commandTimeout}`);
  }
  
  return parts.join(';');
}

/**
 * Validate vector dimensions
 */
export function validateEmbedding(embedding: number[], expectedDims: number): void {
  if (!Array.isArray(embedding)) {
    throw new HANAError(
      'Embedding must be an array',
      HANAErrorCode.INVALID_INPUT
    );
  }
  
  if (embedding.length !== expectedDims) {
    throw new HANAError(
      `Embedding dimension mismatch: expected ${expectedDims}, got ${embedding.length}`,
      HANAErrorCode.INVALID_INPUT
    );
  }
  
  // Check for valid numbers
  for (let i = 0; i < embedding.length; i++) {
    if (typeof embedding[i] !== 'number' || !isFinite(embedding[i])) {
      throw new HANAError(
        `Invalid embedding value at index ${i}`,
        HANAErrorCode.INVALID_INPUT
      );
    }
  }
}

/**
 * Convert embedding array to HANA vector string format
 */
export function embeddingToVectorString(embedding: number[]): string {
  return `[${embedding.join(',')}]`;
}

/**
 * Parse HANA vector string to embedding array
 */
export function vectorStringToEmbedding(vectorString: string): number[] {
  // Handle binary format or string format
  if (Buffer.isBuffer(vectorString)) {
    // Parse binary vector format
    // HANA stores vectors as binary with float32 values
    const floatArray = new Float32Array(
      (vectorString as unknown as Buffer).buffer,
      (vectorString as unknown as Buffer).byteOffset,
      (vectorString as unknown as Buffer).length / 4
    );
    return Array.from(floatArray);
  }
  
  // Parse string format: "[0.1,0.2,0.3]"
  const cleaned = vectorString.replace(/[\[\]]/g, '');
  return cleaned.split(',').map(v => parseFloat(v.trim()));
}

/**
 * Escape SQL identifier
 */
export function escapeIdentifier(identifier: string): string {
  // Double quotes for HANA identifiers
  return `"${identifier.replace(/"/g, '""')}"`;
}

/**
 * Escape SQL string value
 */
export function escapeString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}