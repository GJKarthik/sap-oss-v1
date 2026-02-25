/**
 * SAP HANA Cloud Client
 * 
 * Connection management and query execution for HANA Cloud
 */

import {
  type HANAConfig,
  type PoolConfig,
  type QueryResult,
  type TableDefinition,
  type ColumnMetadata,
  HANAError,
  HANAErrorCode,
  buildConnectionString,
  escapeIdentifier,
} from './types.js';

// Type definitions for @sap/hana-client (declared manually since types may not be available)
interface HanaConnection {
  connect(callback: (err: Error | null) => void): void;
  disconnect(callback?: (err: Error | null) => void): void;
  exec(sql: string, callback: (err: Error | null, result: unknown) => void): void;
  exec(sql: string, params: unknown[], callback: (err: Error | null, result: unknown) => void): void;
  prepare(sql: string, callback: (err: Error | null, stmt: HanaStatement) => void): void;
  commit(callback: (err: Error | null) => void): void;
  rollback(callback: (err: Error | null) => void): void;
  setAutoCommit(autoCommit: boolean): void;
}

interface HanaStatement {
  exec(params: unknown[], callback: (err: Error | null, result: unknown) => void): void;
  execBatch(params: unknown[][], callback: (err: Error | null, result: unknown) => void): void;
  drop(callback?: (err: Error | null) => void): void;
}

interface HanaClientModule {
  createConnection(config: Record<string, unknown>): HanaConnection;
}

// ============================================================================
// Connection Pool
// ============================================================================

/**
 * Simple connection pool for HANA connections
 */
class ConnectionPool {
  private available: HanaConnection[] = [];
  private inUse: Set<HanaConnection> = new Set();
  private waitQueue: Array<{
    resolve: (conn: HanaConnection) => void;
    reject: (err: Error) => void;
    timeout: NodeJS.Timeout;
  }> = [];
  private closed = false;
  private hanaClient: HanaClientModule | null = null;

  constructor(
    private config: HANAConfig,
    private poolConfig: PoolConfig = {}
  ) {
    this.poolConfig = {
      min: poolConfig.min ?? 1,
      max: poolConfig.max ?? 10,
      acquireTimeout: poolConfig.acquireTimeout ?? 30000,
      idleTimeout: poolConfig.idleTimeout ?? 60000,
    };
  }

  /**
   * Initialize the pool
   */
  async init(): Promise<void> {
    // Dynamically import @sap/hana-client
    try {
      this.hanaClient = await import('@sap/hana-client') as unknown as HanaClientModule;
    } catch (error) {
      throw new HANAError(
        'Failed to load @sap/hana-client. Ensure it is installed.',
        HANAErrorCode.CONNECTION_FAILED,
        undefined,
        undefined,
        error as Error
      );
    }

    // Create minimum connections
    const minConnections = this.poolConfig.min || 1;
    const connectionPromises: Promise<void>[] = [];
    
    for (let i = 0; i < minConnections; i++) {
      connectionPromises.push(
        this.createConnection().then(conn => {
          this.available.push(conn);
        })
      );
    }
    
    await Promise.all(connectionPromises);
  }

  /**
   * Create a new connection
   */
  private createConnection(): Promise<HanaConnection> {
    return new Promise((resolve, reject) => {
      if (!this.hanaClient) {
        reject(new HANAError(
          'HANA client not initialized',
          HANAErrorCode.CONNECTION_FAILED
        ));
        return;
      }

      const connParams = {
        serverNode: `${this.config.host}:${this.config.port || 443}`,
        uid: this.config.user,
        pwd: this.config.password,
        encrypt: this.config.encrypt !== false,
        sslValidateCertificate: this.config.sslValidateCertificate !== false,
        currentSchema: this.config.currentSchema || this.config.schema,
        connectTimeout: this.config.connectTimeout,
        communicationTimeout: this.config.commandTimeout,
      };

      const conn = this.hanaClient.createConnection(connParams);
      
      conn.connect((err) => {
        if (err) {
          reject(this.mapError(err, 'connect'));
        } else {
          resolve(conn);
        }
      });
    });
  }

  /**
   * Acquire a connection from the pool
   */
  async acquire(): Promise<HanaConnection> {
    if (this.closed) {
      throw new HANAError(
        'Connection pool is closed',
        HANAErrorCode.CONNECTION_FAILED
      );
    }

    // Try to get an available connection
    if (this.available.length > 0) {
      const conn = this.available.pop()!;
      this.inUse.add(conn);
      return conn;
    }

    // Create a new connection if under max
    const totalConnections = this.available.length + this.inUse.size;
    if (totalConnections < (this.poolConfig.max || 10)) {
      const conn = await this.createConnection();
      this.inUse.add(conn);
      return conn;
    }

    // Wait for a connection to become available
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const index = this.waitQueue.findIndex(w => w.resolve === resolve);
        if (index !== -1) {
          this.waitQueue.splice(index, 1);
        }
        reject(new HANAError(
          'Timeout waiting for connection',
          HANAErrorCode.POOL_EXHAUSTED
        ));
      }, this.poolConfig.acquireTimeout || 30000);

      this.waitQueue.push({ resolve, reject, timeout });
    });
  }

  /**
   * Release a connection back to the pool
   */
  release(conn: HanaConnection): void {
    if (!this.inUse.has(conn)) {
      return;
    }

    this.inUse.delete(conn);

    // If there are waiters, give them the connection
    if (this.waitQueue.length > 0) {
      const waiter = this.waitQueue.shift()!;
      clearTimeout(waiter.timeout);
      this.inUse.add(conn);
      waiter.resolve(conn);
      return;
    }

    // Otherwise return to available pool
    this.available.push(conn);
  }

  /**
   * Close all connections
   */
  async close(): Promise<void> {
    this.closed = true;

    // Reject all waiters
    for (const waiter of this.waitQueue) {
      clearTimeout(waiter.timeout);
      waiter.reject(new HANAError(
        'Connection pool closed',
        HANAErrorCode.CONNECTION_FAILED
      ));
    }
    this.waitQueue = [];

    // Close all connections
    const allConnections = [...this.available, ...this.inUse];
    const closePromises = allConnections.map(conn => 
      new Promise<void>((resolve) => {
        conn.disconnect(() => resolve());
      })
    );

    await Promise.all(closePromises);
    this.available = [];
    this.inUse.clear();
  }

  /**
   * Get pool statistics
   */
  getStats(): { available: number; inUse: number; waiting: number } {
    return {
      available: this.available.length,
      inUse: this.inUse.size,
      waiting: this.waitQueue.length,
    };
  }

  /**
   * Map HANA errors to HANAError
   */
  private mapError(error: Error & { code?: number; sqlState?: string }, operation: string): HANAError {
    const sqlCode = error.code;
    const sqlState = error.sqlState;

    // Map specific error codes
    if (sqlCode === 10) {
      return new HANAError(
        'Authentication failed',
        HANAErrorCode.AUTH_FAILED,
        sqlCode,
        sqlState,
        error
      );
    }

    if (sqlCode === -10709) {
      return new HANAError(
        'Connection failed',
        HANAErrorCode.CONNECTION_FAILED,
        sqlCode,
        sqlState,
        error
      );
    }

    return new HANAError(
      error.message || `Failed to ${operation}`,
      HANAErrorCode.UNKNOWN,
      sqlCode,
      sqlState,
      error
    );
  }
}

// ============================================================================
// HANA Client
// ============================================================================

/**
 * HANA Cloud Client
 * 
 * Provides connection management and query execution for SAP HANA Cloud
 */
export class HANAClient {
  private pool: ConnectionPool;
  private initialized = false;

  constructor(
    private config: HANAConfig,
    poolConfig?: PoolConfig
  ) {
    this.validateConfig(config);
    this.pool = new ConnectionPool(config, poolConfig);
  }

  /**
   * Validate configuration
   */
  private validateConfig(config: HANAConfig): void {
    if (!config.host) {
      throw new HANAError(
        'Host is required',
        HANAErrorCode.INVALID_INPUT
      );
    }

    if (!config.user || !config.password) {
      throw new HANAError(
        'User and password are required',
        HANAErrorCode.INVALID_INPUT
      );
    }
  }

  /**
   * Initialize the client
   */
  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }

    await this.pool.init();
    this.initialized = true;
  }

  /**
   * Ensure client is initialized
   */
  private async ensureInitialized(): Promise<void> {
    if (!this.initialized) {
      await this.init();
    }
  }

  /**
   * Map HANA errors
   */
  private mapError(error: Error & { code?: number; sqlState?: string }, operation: string): HANAError {
    const sqlCode = error.code;
    const sqlState = error.sqlState;

    // Map specific SQL error codes
    if (sqlCode === 259) {
      return new HANAError(
        'Table not found',
        HANAErrorCode.TABLE_NOT_FOUND,
        sqlCode,
        sqlState,
        error
      );
    }

    if (sqlCode === 260) {
      return new HANAError(
        'Column not found',
        HANAErrorCode.COLUMN_NOT_FOUND,
        sqlCode,
        sqlState,
        error
      );
    }

    if (sqlCode === 301) {
      return new HANAError(
        'Duplicate key violation',
        HANAErrorCode.DUPLICATE_KEY,
        sqlCode,
        sqlState,
        error
      );
    }

    if (sqlCode === 461 || sqlCode === 462) {
      return new HANAError(
        'Constraint violation',
        HANAErrorCode.CONSTRAINT_VIOLATION,
        sqlCode,
        sqlState,
        error
      );
    }

    return new HANAError(
      error.message || `Failed to ${operation}`,
      HANAErrorCode.QUERY_FAILED,
      sqlCode,
      sqlState,
      error
    );
  }

  // ==========================================================================
  // Query Operations
  // ==========================================================================

  /**
   * Execute a SQL query
   */
  async query<T = Record<string, unknown>>(
    sql: string,
    params?: unknown[]
  ): Promise<T[]> {
    await this.ensureInitialized();
    
    const conn = await this.pool.acquire();
    
    try {
      return await new Promise((resolve, reject) => {
        const callback = (err: Error | null, result: unknown) => {
          if (err) {
            reject(this.mapError(err as Error & { code?: number }, 'query'));
          } else {
            resolve((result as T[]) || []);
          }
        };

        if (params && params.length > 0) {
          conn.exec(sql, params, callback);
        } else {
          conn.exec(sql, callback);
        }
      });
    } finally {
      this.pool.release(conn);
    }
  }

  /**
   * Execute a SQL statement (INSERT, UPDATE, DELETE)
   */
  async execute(sql: string, params?: unknown[]): Promise<number> {
    await this.ensureInitialized();
    
    const conn = await this.pool.acquire();
    
    try {
      return await new Promise((resolve, reject) => {
        const callback = (err: Error | null, result: unknown) => {
          if (err) {
            reject(this.mapError(err as Error & { code?: number }, 'execute'));
          } else {
            // For DML, result is the number of affected rows
            const affectedRows = typeof result === 'number' ? result : 0;
            resolve(affectedRows);
          }
        };

        if (params && params.length > 0) {
          conn.exec(sql, params, callback);
        } else {
          conn.exec(sql, callback);
        }
      });
    } finally {
      this.pool.release(conn);
    }
  }

  /**
   * Execute a batch of statements with the same SQL
   */
  async executeBatch(sql: string, paramsBatch: unknown[][]): Promise<number> {
    await this.ensureInitialized();
    
    if (paramsBatch.length === 0) {
      return 0;
    }

    const conn = await this.pool.acquire();
    
    try {
      return await new Promise((resolve, reject) => {
        conn.prepare(sql, (prepErr, stmt) => {
          if (prepErr) {
            reject(this.mapError(prepErr as Error & { code?: number }, 'prepare'));
            return;
          }

          stmt.execBatch(paramsBatch, (execErr, result) => {
            stmt.drop();
            
            if (execErr) {
              reject(this.mapError(execErr as Error & { code?: number }, 'executeBatch'));
            } else {
              const affectedRows = Array.isArray(result) 
                ? result.reduce((sum: number, r: unknown) => sum + (typeof r === 'number' ? r : 1), 0)
                : (typeof result === 'number' ? result : paramsBatch.length);
              resolve(affectedRows);
            }
          });
        });
      });
    } finally {
      this.pool.release(conn);
    }
  }

  /**
   * Execute within a transaction
   */
  async transaction<T>(fn: (client: TransactionClient) => Promise<T>): Promise<T> {
    await this.ensureInitialized();
    
    const conn = await this.pool.acquire();
    conn.setAutoCommit(false);

    const txClient = new TransactionClient(conn, (err, op) => this.mapError(err, op));

    try {
      const result = await fn(txClient);
      
      await new Promise<void>((resolve, reject) => {
        conn.commit((err) => {
          if (err) reject(this.mapError(err as Error & { code?: number }, 'commit'));
          else resolve();
        });
      });
      
      return result;
    } catch (error) {
      await new Promise<void>((resolve) => {
        conn.rollback(() => resolve());
      });
      throw error;
    } finally {
      conn.setAutoCommit(true);
      this.pool.release(conn);
    }
  }

  // ==========================================================================
  // Schema Operations
  // ==========================================================================

  /**
   * Create a table
   */
  async createTable(definition: TableDefinition): Promise<void> {
    const tableName = definition.schema 
      ? `${escapeIdentifier(definition.schema)}.${escapeIdentifier(definition.name)}`
      : escapeIdentifier(definition.name);

    const columnDefs = definition.columns.map(col => {
      let def = `${escapeIdentifier(col.name)} ${col.type}`;
      if (col.nullable === false) {
        def += ' NOT NULL';
      }
      if (col.defaultValue) {
        def += ` DEFAULT ${col.defaultValue}`;
      }
      return def;
    });

    if (definition.primaryKey && definition.primaryKey.length > 0) {
      const pkCols = definition.primaryKey.map(c => escapeIdentifier(c)).join(', ');
      columnDefs.push(`PRIMARY KEY (${pkCols})`);
    }

    const sql = `CREATE TABLE ${tableName} (${columnDefs.join(', ')})`;
    await this.execute(sql);
  }

  /**
   * Drop a table
   */
  async dropTable(tableName: string, schema?: string): Promise<void> {
    const fullName = schema 
      ? `${escapeIdentifier(schema)}.${escapeIdentifier(tableName)}`
      : escapeIdentifier(tableName);
    
    await this.execute(`DROP TABLE ${fullName}`);
  }

  /**
   * Check if table exists
   */
  async tableExists(tableName: string, schema?: string): Promise<boolean> {
    const sql = `
      SELECT COUNT(*) as CNT FROM TABLES 
      WHERE TABLE_NAME = ? 
      ${schema ? 'AND SCHEMA_NAME = ?' : ''}
    `;
    
    const params = schema ? [tableName, schema] : [tableName];
    const result = await this.query<{ CNT: number }>(sql, params);
    
    return result[0]?.CNT > 0;
  }

  /**
   * Get table columns
   */
  async getTableColumns(tableName: string, schema?: string): Promise<ColumnMetadata[]> {
    const sql = `
      SELECT 
        COLUMN_NAME as "name",
        DATA_TYPE_NAME as "type",
        IS_NULLABLE as "nullable",
        LENGTH as "length",
        PRECISION as "precision",
        SCALE as "scale"
      FROM TABLE_COLUMNS 
      WHERE TABLE_NAME = ? 
      ${schema ? 'AND SCHEMA_NAME = ?' : ''}
      ORDER BY POSITION
    `;
    
    const params = schema ? [tableName, schema] : [tableName];
    const result = await this.query<{
      name: string;
      type: string;
      nullable: string;
      length: number;
      precision: number;
      scale: number;
    }>(sql, params);
    
    return result.map(row => ({
      name: row.name,
      type: row.type,
      nullable: row.nullable === 'TRUE',
      length: row.length,
      precision: row.precision,
      scale: row.scale,
    }));
  }

  // ==========================================================================
  // Utility Methods
  // ==========================================================================

  /**
   * Get pool statistics
   */
  getPoolStats(): { available: number; inUse: number; waiting: number } {
    return this.pool.getStats();
  }

  /**
   * Close all connections
   */
  async close(): Promise<void> {
    await this.pool.close();
    this.initialized = false;
  }

  /**
   * Ping the database
   */
  async ping(): Promise<boolean> {
    try {
      await this.query('SELECT 1 FROM DUMMY');
      return true;
    } catch {
      return false;
    }
  }
}

// ============================================================================
// Transaction Client
// ============================================================================

/**
 * Client for transaction operations
 */
class TransactionClient {
  constructor(
    private conn: HanaConnection,
    private mapError: (err: Error & { code?: number }, operation: string) => HANAError
  ) {}

  /**
   * Execute a query within the transaction
   */
  async query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]> {
    return new Promise((resolve, reject) => {
      const callback = (err: Error | null, result: unknown) => {
        if (err) {
          reject(this.mapError(err as Error & { code?: number }, 'query'));
        } else {
          resolve((result as T[]) || []);
        }
      };

      if (params && params.length > 0) {
        this.conn.exec(sql, params, callback);
      } else {
        this.conn.exec(sql, callback);
      }
    });
  }

  /**
   * Execute a statement within the transaction
   */
  async execute(sql: string, params?: unknown[]): Promise<number> {
    return new Promise((resolve, reject) => {
      const callback = (err: Error | null, result: unknown) => {
        if (err) {
          reject(this.mapError(err as Error & { code?: number }, 'execute'));
        } else {
          const affectedRows = typeof result === 'number' ? result : 0;
          resolve(affectedRows);
        }
      };

      if (params && params.length > 0) {
        this.conn.exec(sql, params, callback);
      } else {
        this.conn.exec(sql, callback);
      }
    });
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a HANA client
 */
export function createHANAClient(config: HANAConfig, poolConfig?: PoolConfig): HANAClient {
  return new HANAClient(config, poolConfig);
}

/**
 * Create a HANA client from environment variables
 */
export function createHANAClientFromEnv(poolConfig?: PoolConfig): HANAClient {
  const config: HANAConfig = {
    host: process.env.HANA_HOST || process.env.HANA_SERVERNODE?.split(':')[0] || '',
    port: parseInt(process.env.HANA_PORT || process.env.HANA_SERVERNODE?.split(':')[1] || '443', 10),
    user: process.env.HANA_USER || process.env.HANA_UID || '',
    password: process.env.HANA_PASSWORD || process.env.HANA_PWD || '',
    schema: process.env.HANA_SCHEMA,
    encrypt: process.env.HANA_ENCRYPT !== 'false',
    sslValidateCertificate: process.env.HANA_SSL_VALIDATE !== 'false',
  };

  return new HANAClient(config, poolConfig);
}

export { TransactionClient };