/**
 * MCP Service - Angular Service for Backend Communication
 *
 * Routes MCP traffic through the FastAPI proxy so browser requests stay behind
 * the same auth, CORS, and correlation-id policy as the rest of the console.
 */

import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { BehaviorSubject, Observable, Subscription, catchError, forkJoin, interval, map, of, switchMap, timeout } from 'rxjs';
import { environment } from '../../environments/environment';
import { AuthService } from './auth.service';

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

interface DeploymentResponse {
  id: string;
  status: string;
  details?: Record<string, unknown>;
  target_status?: string;
  scenario_id?: string;
  creation_time?: string;
}

interface DeploymentListResponse {
  resources: DeploymentResponse[];
  count: number;
}

export interface MCPToolDefinition {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

interface DashboardStatsResponse {
  total_deployments: number;
  running_deployments: number;
  total_vector_stores: number;
  total_documents: number;
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
  availablePalTools: number;
  totalKnowledgeBases: number;
  documentsIndexed: number;
  overallHealth: 'healthy' | 'degraded' | 'error' | 'unknown';
}

export interface ElasticsearchClusterHealth {
  cluster_name?: string;
  status?: string;
  number_of_nodes?: number;
  active_shards?: number;
  [key: string]: unknown;
}

export interface GenUiSessionMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp?: string;
}

export interface GenUiSession {
  id: string;
  title: string;
  owner_username: string;
  is_bookmarked: boolean;
  messages: GenUiSessionMessage[];
  ui_state: Record<string, unknown>;
  created_at: string;
  updated_at: string;
  last_message_at?: string | null;
  is_archived?: boolean;
  archived_at?: string | null;
}

export interface GenUiSessionListResponse {
  sessions: GenUiSession[];
  total: number;
}

export interface OperationsDashboard {
  window_seconds: number;
  api: {
    requests_total: number;
    error_requests_total: number;
    error_rate: number;
    avg_latency_ms: number;
    handlers: Array<{
      handler: string;
      method: string;
      requests: number;
      errors: number;
      avg_latency_ms: number;
    }>;
  };
  auth: {
    successes_total: number;
    failures_total: number;
    recent_failures: number;
  };
  mcp: {
    recent_failures: Record<string, number>;
    services: Record<string, {
      request_successes_total: number;
      request_failures_total: number;
      healthy: boolean;
    }>;
    service_health: Array<{
      status: string;
      service: string;
      target: string;
      error?: string;
    }>;
  };
  store: {
    store: string;
    store_backend: string;
    connection_target: string;
    [key: string]: unknown;
  };
  audit: {
    total_actions: number;
    failed_actions: number;
  };
  alerts: Array<{
    name: string;
    active: boolean;
    observed: unknown;
    threshold: number;
    window_seconds: number;
  }>;
}

// =============================================================================
// MCP Service
// =============================================================================

@Injectable({
  providedIn: 'root'
})
export class McpService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly requestTimeoutMs = 15000;

  private requestId = 0;
  private correlationCounter = 0;
  private readonly elasticsearchUrl = environment.elasticsearchMcpUrl;
  private readonly palUrl = environment.palMcpUrl;
  private readonly elasticsearchHealthUrl = `${environment.elasticsearchMcpUrl}/health`;
  private readonly palHealthUrl = `${environment.palMcpUrl}/health`;
  private healthPollingSubscription: Subscription | null = null;

  // Reactive state
  private healthSubject = new BehaviorSubject<{
    elasticsearch: ServiceHealth | null;
    pal: ServiceHealth | null;
    overall: 'healthy' | 'degraded' | 'error' | 'unknown';
  }>({ elasticsearch: null, pal: null, overall: 'unknown' });

  private deploymentsSubject = new BehaviorSubject<Deployment[]>([]);
  private vectorStoresSubject = new BehaviorSubject<VectorStore[]>([]);

  // Public observables
  public health$ = this.healthSubject.asObservable();
  public deployments$ = this.deploymentsSubject.asObservable();
  public vectorStores$ = this.vectorStoresSubject.asObservable();

  constructor() {
    this.authService.isAuthenticated$.subscribe(isAuthenticated => {
      if (isAuthenticated) {
        this.startHealthPolling();
        return;
      }

      this.stopHealthPolling();
    });
  }

  // ===========================================================================
  // Health Checks
  // ===========================================================================

  private startHealthPolling(): void {
    if (this.healthPollingSubscription) {
      return;
    }

    this.healthPollingSubscription = interval(30000).pipe(
      switchMap(() => this.checkAllHealth())
    ).subscribe();

    this.checkAllHealth().subscribe();
  }

  private stopHealthPolling(): void {
    this.healthPollingSubscription?.unsubscribe();
    this.healthPollingSubscription = null;
    this.healthSubject.next({ elasticsearch: null, pal: null, overall: 'unknown' });
  }

  checkAllHealth(): Observable<void> {
    const elasticsearchHealth$ = this.http.get<ServiceHealth>(
      this.elasticsearchHealthUrl
    ).pipe(
      catchError(err => of<ServiceHealth>({
        status: 'error',
        service: 'elasticsearch-mcp',
        error: err.message || 'Connection failed'
      }))
    );

    const palHealth$ = this.http.get<ServiceHealth>(
      this.palHealthUrl
    ).pipe(
      catchError(err => of<ServiceHealth>({
        status: 'error',
        service: 'ai-core-pal-mcp',
        error: err.message || 'Connection failed'
      }))
    );

    return forkJoin({
      elasticsearch: elasticsearchHealth$,
      pal: palHealth$
    }).pipe(
      map(({ elasticsearch, pal }) => {
        let overall: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
        if (elasticsearch.status === 'healthy' && pal.status === 'healthy') {
          overall = 'healthy';
        } else if (elasticsearch.status === 'error' && pal.status === 'error') {
          overall = 'error';
        } else {
          overall = 'degraded';
        }

        this.healthSubject.next({ elasticsearch, pal, overall });
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

  private normalizeDeployment(deployment: DeploymentResponse): Deployment {
    return {
      id: deployment.id,
      status: deployment.status,
      details: deployment.details,
      targetStatus: deployment.target_status,
      scenarioId: deployment.scenario_id,
      creationTime: deployment.creation_time,
    };
  }

  private withRequestTimeout<T>(request$: Observable<T>): Observable<T> {
    return request$.pipe(timeout({ first: this.requestTimeoutMs }));
  }

  private mcpRequest<T>(endpoint: string, method: string, params: Record<string, unknown> = {}): Observable<T> {
    const request: MCPRequest = {
      jsonrpc: '2.0',
      id: ++this.requestId,
      method,
      params
    };

    return this.withRequestTimeout(
      this.http.post<MCPResponse<T>>(endpoint, request, { headers: this.getHeaders() })
    ).pipe(
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
        if (!text) {
          return result as T;
        }
        try {
          return JSON.parse(text) as T;
        } catch {
          return text as T;
        }
      })
    );
  }

  // ===========================================================================
  // Deployments
  // ===========================================================================

  fetchDeployments(): Observable<Deployment[]> {
    return this.withRequestTimeout(
      this.http.get<DeploymentListResponse>(`${environment.apiBaseUrl}/deployments`)
    ).pipe(
      map(result => {
        const deployments = (result.resources || []).map(deployment => this.normalizeDeployment(deployment));
        this.deploymentsSubject.next(deployments);
        return deployments;
      })
    );
  }

  createDeployment(scenarioId: string, configuration: Record<string, unknown> = {}): Observable<Deployment> {
    return this.withRequestTimeout(
      this.http.post<DeploymentResponse>(`${environment.apiBaseUrl}/deployments`, {
        scenario_id: scenarioId,
        configuration,
      })
    ).pipe(
      map(deployment => this.normalizeDeployment(deployment))
    );
  }

  updateDeploymentStatus(deploymentId: string, targetStatus: string): Observable<{ id: string; target_status: string }> {
    return this.withRequestTimeout(
      this.http.patch<{ id: string; target_status: string }>(
        `${environment.apiBaseUrl}/deployments/${deploymentId}/status`,
        { target_status: targetStatus }
      )
    );
  }

  deleteDeployment(deploymentId: string): Observable<void> {
    return this.withRequestTimeout(
      this.http.delete<void>(`${environment.apiBaseUrl}/deployments/${deploymentId}`)
    );
  }

  // ===========================================================================
  // PAL / Elasticsearch
  // ===========================================================================

  fetchPalTools(): Observable<MCPToolDefinition[]> {
    return this.mcpRequest<{ tools?: MCPToolDefinition[] }>(this.palUrl, 'tools/list').pipe(
      map(result => result.tools || [])
    );
  }

  invokePalTool<T>(toolName: string, args: Record<string, unknown>): Observable<T> {
    return this.callTool<T>(this.palUrl, toolName, args);
  }

  getElasticsearchClusterHealth(): Observable<ElasticsearchClusterHealth> {
    return this.callTool<ElasticsearchClusterHealth>(this.elasticsearchUrl, 'es_cluster_health', {});
  }

  // ===========================================================================
  // Vector Stores
  // ===========================================================================

  fetchVectorStores(): Observable<VectorStore[]> {
    return this.withRequestTimeout(
      this.http.get<VectorStore[]>(`${environment.apiBaseUrl}/rag/stores`)
    ).pipe(
      map(result => {
        const stores = result || [];
        this.vectorStoresSubject.next(stores);
        return stores;
      })
    );
  }

  createVectorStore(tableName: string, embeddingModel = 'default'): Observable<VectorStore> {
    return this.withRequestTimeout(
      this.http.post<VectorStore>(`${environment.apiBaseUrl}/rag/stores`, {
        table_name: tableName,
        embedding_model: embeddingModel,
      })
    );
  }

  addDocuments(tableName: string, documents: string[], metadatas?: Record<string, unknown>[]): Observable<{ documents_added: number; status: string }> {
    return this.withRequestTimeout(
      this.http.post<{ documents_added: number; status: string }>(`${environment.apiBaseUrl}/rag/documents`, {
        table_name: tableName,
        documents,
        metadatas,
      })
    );
  }

  // ===========================================================================
  // RAG
  // ===========================================================================

  ragQuery(query: string, tableName: string, k = 4): Observable<RAGResult> {
    return this.withRequestTimeout(
      this.http.post<RAGResult>(`${environment.apiBaseUrl}/rag/query`, {
        query,
        table_name: tableName,
        k,
      })
    );
  }

  similaritySearch(tableName: string, query: string, k = 4): Observable<{ results: unknown[]; status: string }> {
    return this.withRequestTimeout(
      this.http.post<{ results: unknown[]; status: string }>(`${environment.apiBaseUrl}/rag/similarity-search`, {
        table_name: tableName,
        query,
        k,
      })
    );
  }

  // ===========================================================================
  // KùzuDB Graph
  // ===========================================================================

  kuzuQuery(cypher: string, params?: Record<string, unknown>): Observable<{ rows: unknown[]; rowCount: number }> {
    return this.withRequestTimeout(
      this.http.post<{ rows: unknown[]; row_count: number }>(`${environment.apiBaseUrl}/lineage/query`, {
        cypher,
        params,
      })
    ).pipe(
      map(result => ({
        rows: result.rows,
        rowCount: result.row_count,
      }))
    );
  }

  graphSummary(): Observable<{
    node_count: number;
    edge_count: number;
    node_types: Array<{ type: string; count: number }>;
    edge_types: Array<{ type: string; count: number }>;
    status?: string;
    error?: string;
  }> {
    return this.withRequestTimeout(
      this.http.get<{
        node_count: number;
        edge_count: number;
        node_types: Array<{ type: string; count: number }>;
        edge_types: Array<{ type: string; count: number }>;
        status?: string;
        error?: string;
      }>(`${environment.apiBaseUrl}/lineage/graph/summary`)
    );
  }

  kuzuIndex(entities: {
    vector_stores?: unknown[];
    deployments?: unknown[];
    schemas?: unknown[];
  }): Observable<{ stores_indexed: number; deployments_indexed: number; schemas_indexed: number }> {
    return this.withRequestTimeout(
      this.http.post<{ stores_indexed: number; deployments_indexed: number; schemas_indexed: number }>(
        `${environment.apiBaseUrl}/lineage/index`,
        {
          vector_stores: entities.vector_stores || [],
          deployments: entities.deployments || [],
          schemas: entities.schemas || [],
        }
      )
    );
  }

  // ===========================================================================
  // Dashboard Stats
  // ===========================================================================

  getDashboardStats(): Observable<DashboardStats> {
    return forkJoin({
      dashboard: this.withRequestTimeout(
        this.http.get<DashboardStatsResponse>(`${environment.apiBaseUrl}/metrics/dashboard`)
      ),
      palTools: this.fetchPalTools(),
    }).pipe(
      map(({ dashboard, palTools }) => {
        const health = this.healthSubject.getValue();

        return {
          servicesHealthy: (health.elasticsearch?.status === 'healthy' ? 1 : 0) +
            (health.pal?.status === 'healthy' ? 1 : 0),
          totalServices: 2,
          activeDeployments: dashboard.running_deployments,
          totalDeployments: dashboard.total_deployments,
          availablePalTools: palTools.length,
          totalKnowledgeBases: dashboard.total_vector_stores,
          documentsIndexed: dashboard.total_documents,
          overallHealth: health.overall,
        } satisfies DashboardStats;
      })
    );
  }

  getOperationsDashboard(): Observable<OperationsDashboard> {
    return this.withRequestTimeout(
      this.http.get<OperationsDashboard>(`${environment.apiBaseUrl}/metrics/operations`)
    ).pipe(
      catchError(() => of({
        window_seconds: 300,
        api: {
          requests_total: 0,
          error_requests_total: 0,
          error_rate: 0,
          avg_latency_ms: 0,
          handlers: []
        },
        auth: {
          successes_total: 0,
          failures_total: 0,
          recent_failures: 0
        },
        mcp: {
          recent_failures: {},
          services: {},
          service_health: []
        },
        store: {
          store: 'unknown',
          store_backend: 'unknown',
          connection_target: ''
        },
        audit: {
          total_actions: 0,
          failed_actions: 0
        },
        alerts: []
      }))
    );
  }

  // ===========================================================================
  // Generative UI Session Persistence
  // ===========================================================================

  listGenUiSessions(options?: {
    bookmarkedOnly?: boolean;
    includeArchived?: boolean;
    archivedOnly?: boolean;
    query?: string;
    limit?: number;
  }): Observable<GenUiSessionListResponse> {
    const bookmarkedOnly = options?.bookmarkedOnly ?? false;
    const includeArchived = options?.includeArchived ?? false;
    const archivedOnly = options?.archivedOnly ?? false;
    const query = options?.query ?? '';
    const limit = options?.limit ?? 50;
    return this.withRequestTimeout(
      this.http.get<GenUiSessionListResponse>(`${environment.apiBaseUrl}/genui/sessions`, {
        params: {
          bookmarked_only: String(bookmarkedOnly),
          include_archived: String(includeArchived),
          archived_only: String(archivedOnly),
          query,
          limit: String(limit),
        },
      })
    );
  }

  getGenUiSession(sessionId: string): Observable<GenUiSession> {
    return this.withRequestTimeout(
      this.http.get<GenUiSession>(`${environment.apiBaseUrl}/genui/sessions/${sessionId}`)
    );
  }

  saveGenUiSession(payload: {
    session_id?: string;
    title?: string;
    messages: GenUiSessionMessage[];
    ui_state?: Record<string, unknown>;
  }): Observable<GenUiSession> {
    return this.withRequestTimeout(
      this.http.post<GenUiSession>(`${environment.apiBaseUrl}/genui/sessions/save`, payload)
    );
  }

  setGenUiSessionBookmark(sessionId: string, isBookmarked: boolean): Observable<GenUiSession> {
    return this.withRequestTimeout(
      this.http.patch<GenUiSession>(`${environment.apiBaseUrl}/genui/sessions/${sessionId}/bookmark`, {
        is_bookmarked: isBookmarked,
      })
    );
  }

  setGenUiSessionArchived(sessionId: string, isArchived: boolean): Observable<GenUiSession> {
    return this.withRequestTimeout(
      this.http.patch<GenUiSession>(`${environment.apiBaseUrl}/genui/sessions/${sessionId}/archive`, {
        is_archived: isArchived,
      })
    );
  }

  archiveGenUiSession(sessionId: string): Observable<void> {
    return this.withRequestTimeout(
      this.http.delete<void>(`${environment.apiBaseUrl}/genui/sessions/${sessionId}`)
    );
  }

  cloneGenUiSession(sessionId: string): Observable<GenUiSession> {
    return this.withRequestTimeout(
      this.http.post<GenUiSession>(`${environment.apiBaseUrl}/genui/sessions/${sessionId}/clone`, {})
    );
  }
}
