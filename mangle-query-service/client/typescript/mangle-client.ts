/**
 * TypeScript gRPC client for the Mangle Query Service.
 * Can be imported directly into cap-llm-plugin or any Node.js service.
 */

import * as grpc from '@grpc/grpc-js';
import * as protoLoader from '@grpc/proto-loader';
import * as path from 'path';

export interface MangleConfig {
  address: string;
  timeout?: number; // ms, default: 10000
}

export interface MangleResponse {
  answer: string;
  path: 'cache' | 'factual' | 'rag' | 'llm' | 'llm_fallback' | 'no_match';
  confidence: number;
  sources: Array<{ title: string; content: string; origin: string; score: number }>;
  latencyMs: number;
  correlationId: string;
}

export interface HealthResponse {
  status: 'healthy' | 'degraded' | 'unhealthy';
  components: Record<string, string>;
  metrics: Record<string, number>;
}

export interface SyncEntityResponse {
  success: boolean;
  error: string;
}

export class MangleClient {
  private _client: any;
  private _timeout: number;

  constructor(config: MangleConfig) {
    const PROTO_PATH = path.resolve(__dirname, 'query.proto');
    const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
      keepCase: false,
      longs: String,
      enums: String,
      defaults: true,
      oneofs: true,
    });
    const proto = grpc.loadPackageDefinition(packageDefinition) as any;
    this._client = new proto.mqs.v1.QueryService(
      config.address,
      grpc.credentials.createInsecure()
    );
    this._timeout = config.timeout || 10000;
  }

  /**
   * Resolve a user query through the Mangle routing engine.
   */
  async resolve(
    query: string,
    queryEmbedding: number[] = [],
    correlationId: string = '',
    metadata: Record<string, string> = {}
  ): Promise<MangleResponse> {
    return new Promise((resolve, reject) => {
      this._client.Resolve(
        { query, queryEmbedding, correlationId, metadata },
        { deadline: new Date(Date.now() + this._timeout) },
        (err: Error | null, response: MangleResponse) => {
          if (err) reject(err);
          else resolve(response);
        }
      );
    });
  }

  /**
   * Check service health.
   */
  async health(): Promise<HealthResponse> {
    return new Promise((resolve, reject) => {
      this._client.Health(
        {},
        { deadline: new Date(Date.now() + 5000) },
        (err: Error | null, response: HealthResponse) => {
          if (err) reject(err);
          else resolve(response);
        }
      );
    });
  }

  /**
   * Notify the service of an entity change (CDC event).
   */
  async syncEntity(
    entityType: string,
    entityId: string,
    operation: 'insert' | 'update' | 'delete',
    payloadJson: string = '{}'
  ): Promise<SyncEntityResponse> {
    return new Promise((resolve, reject) => {
      this._client.SyncEntity(
        { entityType, entityId, operation, payloadJson },
        { deadline: new Date(Date.now() + this._timeout) },
        (err: Error | null, response: SyncEntityResponse) => {
          if (err) reject(err);
          else resolve(response);
        }
      );
    });
  }

  /**
   * Close the gRPC connection.
   */
  close(): void {
    this._client.close();
  }
}

export default MangleClient;
