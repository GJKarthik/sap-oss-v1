/**
 * MCP Service - Angular Service for Backend Communication
 * 
 * Routes MCP JSON-RPC calls through the FastAPI backend proxy.
 */

import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { BehaviorSubject, Observable, catchError, forkJoin, interval, map, of, switchMap } from 'rxjs';
import { environment } from '../../environments/environment';

// =============================================================================
// Types
// =============================================================================

export interface MCPRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params: Record<string, unknown>;
}

export interface MCPResponse<T = unknown> {
  jsonrpc: '2.0';
  id: number;
  result?: T;
  error?: { code: number; message: string };
}

export interface MCPToolResult {
  content: Array<{ type: string; text: string }>;
}

export interface ServiceHealth {
  status: 'healthy' | 'degraded' | 'error';
  service: string;
  timestamp?: string;
  config_ready?: boolean;
  error?: string;
}

export interface Deployment {
  id: string;
  status: string;
  details?: Record<string, unknown>;
  targetStatus?: string;
  scenarioId?: string;
  creationTime?: string;
}

export interface StreamSession {
  stream_id: string;
  deployment_id: string;
  status: string;
  config: Record<string, unknown>;
  events: unknown[];
  started_at: number;
}

export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
  status?: string;
}

export interface RAGResult {
  query: string;
  table_name: string;
  context_docs: unknown[];
  answer: string;
  status: string;
  source?: string;
  graphContext?: unknown;
}

export interface DashboardStats {
  servicesHealthy: number;
  totalServices: number;
  activeDeployments: number;
  totalDeployments: number;
  activeStreams: number;
  totalStreams: number;
  vectorStores: number;
  documentsIndexed: number;
  overallHealth: 'healthy' | 'degraded' | 'error' | 'unknown';
}

// =============================================================================
// MCP Service
// =============================================================================

@Injectable({
  providedIn: 'root'
})
export class McpService {
  private readonly http = inject(HttpClient);

  private requestId = 0;
  private correlationCounter = 0;
  private langchainUrl = `${environment.apiBaseUrl}/mcp/langchain`;
  private streamingUrl = `${environment.apiBaseUrl}/mcp/streaming`;
  private langchainHealthUrl = `${environment.apiBaseUrl}/mcp/langchain/health`;
  private streamingHealthUrl = `${environment.apiBaseUrl}/mcp/streaming/health`;

  // Reactive state
  private healthSubject = new BehaviorSubject<{
    langchain: ServiceHealth | null;
    streaming: ServiceHealth | null;
    overall: 'healthy' | 'degraded' | 'error' | 'unknown';
  }>({ langchain: null, streaming: null, overall: 'unknown' });

  private deploymentsSubject = new BehaviorSubject<Deployment[]>([]);
  private streamsSubject = new BehaviorSubject<StreamSession[]>([]);
  private vectorStoresSubject = new BehaviorSubject<VectorStore[]>([]);

  // Public observables
  public health$ = this.healthSubject.asObservable();
  public deployments$ = this.deploymentsSubject.asObservable();
  public streams$ = this.streamsSubject.asObservable();
  public vectorStores$ = this.vectorStoresSubject.asObservable();

  constructor() {
    // Start health polling
    this.startHealthPolling();
  }

  // ===========================================================================
  // Health Checks
  // ===========================================================================

  private startHealthPolling(): void {
    interval(30000).pipe(
      switchMap(() => this.checkAllHealth())
    ).subscribe();
    
    // Initial check
    this.checkAllHealth().subscribe();
  }

  checkAllHealth(): Observable<void> {
    const langchainHealth$ = this.http.get<ServiceHealth>(
      this.langchainHealthUrl
    ).pipe(
      catchError(err => of<ServiceHealth>({
        status: 'error',
        service: 'langchain-hana-mcp',
        error: err.message || 'Connection failed'
      }))
    );

    const streamingHealth$ = this.http.get<ServiceHealth>(
      this.streamingHealthUrl
    ).pipe(
      catchError(err => of<ServiceHealth>({
        status: 'error',
        service: 'ai-core-streaming-mcp',
        error: err.message || 'Connection failed'
      }))
    );

    return forkJoin({
      langchain: langchainHealth$,
      streaming: streamingHealth$
    }).pipe(
      map(({ langchain, streaming }) => {
        let overall: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
        if (langchain.status === 'healthy' && streaming.status === 'healthy') {
          overall = 'healthy';
        } else if (langchain.status === 'error' && streaming.status === 'error') {
          overall = 'error';
        } else {
          overall = 'degraded';
        }

        this.healthSubject.next({ langchain, streaming, overall });
      })
    );
  }

  // ===========================================================================
  // MCP Request Helpers
  // ===========================================================================

  private getHeaders(): HttpHeaders {
    return new HttpHeaders({
      'Content-Type': 'application/json',
      'X-Correlation-ID': this.generateCorrelationId(),
    });
  }

  private generateCorrelationId(): string {
    return `console-${Date.now()}-${++this.correlationCounter}`;
  }

  private mcpRequest<T>(endpoint: string, method: string, params: Record<string, unknown> = {}): Observable<T> {
    const request: MCPRequest = {
      jsonrpc: '2.0',
      id: ++this.requestId,
      method,
      params
    };

    return this.http.post<MCPResponse<T>>(endpoint, request, { headers: this.getHeaders() }).pipe(
      map(response => {
        if (response.error) {
          throw new Error(`MCP Error ${response.error.code}: ${response.error.message}`);
        }
        return response.result!;
      })
    );
  }

  private callTool<T>(endpoint: string, toolName: string, args: Record<string, unknown>): Observable<T> {
    return this.mcpRequest<MCPToolResult>(endpoint, 'tools/call', {
      name: toolName,
      arguments: args
    }).pipe(
      map(result => {
        const text = result.content?.[0]?.text;
        return text ? JSON.parse(text) : result;
      })
    );
  }

  // ===========================================================================
  // Deployments
  // ===========================================================================

  fetchDeployments(): Observable<Deployment[]> {
    return this.callTool<{ resources?: Deployment[]; error?: string }>(
      this.streamingUrl,
      'list_deployments',
      {}
    ).pipe(
      map(result => {
        const deployments = result.resources || [];
        this.deploymentsSubject.next(deployments);
        return deployments;
      }),
      catchError(err => {
        console.error('Failed to fetch deployments:', err);
        return of([]);
      })
    );
  }

  // ===========================================================================
  // Streams
  // ===========================================================================

  fetchStreams(): Observable<StreamSession[]> {
    return this.callTool<{ active_streams?: StreamSession[]; error?: string }>(
      this.streamingUrl,
      'stream_status',
      {}
    ).pipe(
      map(result => {
        const streams = result.active_streams || [];
        this.streamsSubject.next(streams);
        return streams;
      }),
      catchError(err => {
        console.error('Failed to fetch streams:', err);
        return of([]);
      })
    );
  }

  startStream(deploymentId: string, config: Record<string, unknown> = {}): Observable<{ stream_id: string; status: string }> {
    return this.callTool(this.streamingUrl, 'start_stream', {
      deployment_id: deploymentId,
      config: JSON.stringify(config)
    });
  }

  stopStream(streamId: string): Observable<{ stream_id: string; status: string }> {
    return this.callTool(this.streamingUrl, 'stop_stream', { stream_id: streamId });
  }

  // ===========================================================================
  // Vector Stores
  // ===========================================================================

  fetchVectorStores(): Observable<VectorStore[]> {
    return this.callTool<{ predicate: string; results: VectorStore[] }>(
      this.langchainUrl,
      'mangle_query',
      { predicate: 'vector_stores', args: '[]' }
    ).pipe(
      map(result => {
        const stores = result.results || [];
        this.vectorStoresSubject.next(stores);
        return stores;
      }),
      catchError(err => {
        console.error('Failed to fetch vector stores:', err);
        return of([]);
      })
    );
  }

  createVectorStore(tableName: string, embeddingModel = 'default'): Observable<VectorStore> {
    return this.callTool(this.langchainUrl, 'langchain_vector_store', {
      table_name: tableName,
      embedding_model: embeddingModel
    });
  }

  addDocuments(tableName: string, documents: string[], metadatas?: Record<string, unknown>[]): Observable<{ documents_added: number; status: string }> {
    return this.callTool(this.langchainUrl, 'langchain_add_documents', {
      table_name: tableName,
      documents: JSON.stringify(documents),
      metadatas: metadatas ? JSON.stringify(metadatas) : undefined
    });
  }

  // ===========================================================================
  // RAG
  // ===========================================================================

  ragQuery(query: string, tableName: string, k = 4): Observable<RAGResult> {
    return this.callTool(this.langchainUrl, 'langchain_rag_chain', {
      query,
      table_name: tableName,
      k
    });
  }

  similaritySearch(tableName: string, query: string, k = 4): Observable<{ results: unknown[]; status: string }> {
    return this.callTool(this.langchainUrl, 'langchain_similarity_search', {
      table_name: tableName,
      query,
      k
    });
  }

  // ===========================================================================
  // Chat
  // ===========================================================================

  chat(messages: Array<{ role: string; content: string }>, maxTokens = 1024): Observable<{ content: string; model: string }> {
    return this.callTool(this.langchainUrl, 'langchain_chat', {
      messages: JSON.stringify(messages),
      max_tokens: maxTokens
    });
  }

  streamingChat(messages: Array<{ role: string; content: string }>, maxTokens = 1024): Observable<{ content: string; model: string; streaming: boolean }> {
    return this.callTool(this.streamingUrl, 'streaming_chat', {
      messages: JSON.stringify(messages),
      max_tokens: maxTokens
    });
  }

  // ===========================================================================
  // KùzuDB Graph
  // ===========================================================================

  kuzuQuery(cypher: string, params?: Record<string, unknown>): Observable<{ rows: unknown[]; rowCount: number }> {
    return this.callTool(this.langchainUrl, 'kuzu_query', {
      cypher,
      params: params ? JSON.stringify(params) : undefined
    });
  }

  kuzuIndex(entities: {
    vector_stores?: unknown[];
    deployments?: unknown[];
    schemas?: unknown[];
  }): Observable<{ stores_indexed: number; deployments_indexed: number; schemas_indexed: number }> {
    return this.callTool(this.langchainUrl, 'kuzu_index', {
      vector_stores: JSON.stringify(entities.vector_stores || []),
      deployments: JSON.stringify(entities.deployments || []),
      schemas: JSON.stringify(entities.schemas || [])
    });
  }

  // ===========================================================================
  // Dashboard Stats
  // ===========================================================================

  getDashboardStats(): Observable<DashboardStats> {
    return forkJoin({
      deployments: this.fetchDeployments(),
      streams: this.fetchStreams(),
      stores: this.fetchVectorStores(),
    }).pipe(
      map(({ deployments, streams, stores }) => {
        const health = this.healthSubject.getValue();

        return {
          servicesHealthy: (health.langchain?.status === 'healthy' ? 1 : 0) +
                          (health.streaming?.status === 'healthy' ? 1 : 0),
          totalServices: 2,
          activeDeployments: deployments.filter(d => d.status === 'RUNNING' || d.status === 'active').length,
          totalDeployments: deployments.length,
          activeStreams: streams.filter(s => s.status === 'active').length,
          totalStreams: streams.length,
          vectorStores: stores.length,
          documentsIndexed: stores.reduce((sum, s) => sum + (s.documents_added || 0), 0),
          overallHealth: health.overall,
        } satisfies DashboardStats;
      })
    );
  }
}
