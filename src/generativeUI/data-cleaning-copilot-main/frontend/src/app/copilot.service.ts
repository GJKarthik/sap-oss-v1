import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface ChatMessage {
    role: 'user' | 'assistant';
    content: string;
    timestamp?: string;
}

export interface CheckInfo {
    description: string;
    scope: string;
    code: string;
}

export interface SessionConfig {
    main: Record<string, unknown>;
    check_gen: Record<string, unknown>;
    session_model: string;
    agent_model: string;
}

export interface WorkflowGeneratedCheck extends CheckInfo {
    name: string;
    isNew: boolean;
}

export interface WorkflowSummary {
    runId: string;
    status: 'processing' | 'awaiting_approval' | 'completed' | 'error';
    startedAt: string;
    finishedAt?: string;
    userMessage: string;
    assistantResponse: string;
    requestKind: string;
    newCheckNames: string[];
    newCheckCount: number;
    totalChecks: number;
    sessionModel: string;
    agentModel: string;
    generatedChecks: WorkflowGeneratedCheck[];
}

export interface WorkflowSnapshot {
    summary: WorkflowSummary;
    checks: Record<string, CheckInfo>;
    sessionHistory: ChatMessage[];
    checkHistory: ChatMessage[];
    sessionConfig: SessionConfig;
}

export interface WorkflowReview {
    reviewId: string;
    createdAt: string;
    requestKind: string;
    riskLevel: 'medium' | 'high';
    title: string;
    summary: string;
    affectedScope: string[];
    guardrails: string[];
    plannedCalls: Array<{ name: string; summary: string }>;
    userMessage: string;
}

export interface WorkflowAuditEntry {
    id: string;
    timestamp: string;
    runId: string;
    eventType: string;
    status: string;
    message: string;
    requestKind?: string;
    reviewId?: string;
    detail?: string;
}

export interface WorkflowState {
    workflowRun: WorkflowSnapshot | null;
    pendingReview: WorkflowReview | null;
}

export interface WorkflowReplayEvent {
    id: string;
    sequence: number;
    timestamp: string;
    runId: string;
    type: WorkflowStreamEvent['type'];
    payload: WorkflowStreamEvent | Record<string, unknown>;
}

// MCP Server types
export interface MCPToolInfo {
    name: string;
    description: string;
    inputSchema: {
        type: string;
        properties: Record<string, { type: string; description: string }>;
        required?: string[];
    };
}

export interface MCPResourceInfo {
    uri: string;
    name: string;
    description: string;
    mimeType: string;
}

export interface QualityCheckResult {
    check: string;
    table: string;
    score: number;
    status: 'PASS' | 'WARN' | 'FAIL';
}

export interface DataQualityResponse {
    table: string;
    checks: QualityCheckResult[];
    overall_status: string;
    graph_context?: Array<Record<string, unknown>>;
    external_context?: { source: string; result: unknown };
}

export interface SchemaAnalysisResponse {
    schema: string;
    recommendations: string[];
    status: string;
}

export interface DataProfilingResponse {
    table: string;
    row_count: number;
    column_stats: Record<string, { type: string; [key: string]: unknown }>;
    status: string;
}

export interface AnomalyDetectionResponse {
    table: string;
    column: string;
    method: string;
    anomalies_found: number;
    status: string;
}

export interface AIRoutingInfo {
    contains_pii: boolean;
    pii_indicators: string[];
    data_class: string;
    routing_reason: string;
    backend: string;
}

export interface AIChatResponse {
    content: string;
    backend: string;
    routing: AIRoutingInfo;
    model?: string;
}

export type WorkflowStreamEvent =
    | { type: 'run.started'; runId: string; startedAt: string; userMessage: string }
    | { type: 'run.status'; runId: string; status: 'processing'; phase: string }
    | { type: 'approval.required'; runId: string; status: 'awaiting_approval'; review: WorkflowReview }
    | { type: 'assistant.message'; runId: string; content: string }
    | { type: 'workflow.snapshot'; runId: string; snapshot: WorkflowSnapshot }
    | { type: 'run.finished'; runId: string; status: 'completed'; finishedAt: string }
    | { type: 'run.error'; runId: string; status: 'error'; finishedAt: string; error: string };

@Injectable({ providedIn: 'root' })
export class CopilotService {
    private readonly http = inject(HttpClient);
    private readonly base = 'http://localhost:8000/api';
    private readonly mcpBase = 'http://localhost:9110';

    chat(message: string): Observable<{ response: string }> {
        return this.http.post<{ response: string }>(`${this.base}/chat`, { message });
    }

    runWorkflow(message: string, reviewId?: string): Observable<WorkflowStreamEvent> {
        return new Observable<WorkflowStreamEvent>((subscriber) => {
            const controller = new AbortController();

            fetch(`${this.base}/workflow/run`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    Accept: 'text/event-stream',
                },
                body: JSON.stringify({ message, review_id: reviewId }),
                signal: controller.signal,
            })
                .then(async (response) => {
                    if (!response.ok) {
                        throw new Error(`Workflow stream failed: HTTP ${response.status}`);
                    }

                    const reader = response.body?.getReader();
                    if (!reader) {
                        throw new Error('Workflow stream is not readable');
                    }

                    const decoder = new TextDecoder();
                    let buffer = '';

                    while (true) {
                        const { done, value } = await reader.read();
                        if (done) {
                            break;
                        }

                        buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
                        const frames = buffer.split('\n\n');
                        buffer = frames.pop() ?? '';

                        for (const frame of frames) {
                            const event = this.parseWorkflowEvent(frame);
                            if (!event) {
                                continue;
                            }

                            subscriber.next(event);
                            if (event.type === 'run.finished' || event.type === 'run.error') {
                                subscriber.complete();
                                return;
                            }
                        }
                    }

                    const trailingEvent = this.parseWorkflowEvent(buffer);
                    if (trailingEvent) {
                        subscriber.next(trailingEvent);
                    }
                    subscriber.complete();
                })
                .catch((error: Error) => {
                    if (error.name === 'AbortError') {
                        subscriber.complete();
                        return;
                    }

                    subscriber.error(error);
                });

            return () => controller.abort();
        });
    }

    getChecks(): Observable<Record<string, CheckInfo>> {
        return this.http.get<Record<string, CheckInfo>>(`${this.base}/checks`);
    }

    getSessionHistory(limit = 10): Observable<ChatMessage[]> {
        return this.http.get<ChatMessage[]>(`${this.base}/session-history`, { params: { limit } });
    }

    getCheckHistory(limit = 5): Observable<ChatMessage[]> {
        return this.http.get<ChatMessage[]>(`${this.base}/check-history`, { params: { limit } });
    }

    getSessionConfig(): Observable<SessionConfig> {
        return this.http.get<SessionConfig>(`${this.base}/session-config`);
    }

    getWorkflowAudit(limit = 50): Observable<WorkflowAuditEntry[]> {
        return this.http.get<WorkflowAuditEntry[]>(`${this.base}/workflow/audit`, { params: { limit } });
    }

    getWorkflowState(): Observable<WorkflowState> {
        return this.http.get<WorkflowState>(`${this.base}/workflow/state`);
    }

    getWorkflowEvents(runId?: string, limit = 100): Observable<WorkflowReplayEvent[]> {
        const params: Record<string, string | number> = { limit };
        if (runId) {
            params['run_id'] = runId;
        }
        return this.http.get<WorkflowReplayEvent[]>(`${this.base}/workflow/events`, { params });
    }

    rejectWorkflowReview(reviewId: string): Observable<{ status: string; reviewId: string }> {
        return this.http.post<{ status: string; reviewId: string }>(`${this.base}/workflow/reviews/${reviewId}/reject`, {});
    }

    clearSession(): Observable<{ status: string }> {
        return this.http.delete<{ status: string }>(`${this.base}/session`);
    }

    health(): Observable<{ status: string; session_ready: boolean }> {
        return this.http.get<{ status: string; session_ready: boolean }>(`${this.base}/health`);
    }

    private parseWorkflowEvent(frame: string): WorkflowStreamEvent | null {
        const payload = frame
            .split('\n')
            .filter((line) => line.startsWith('data:'))
            .map((line) => line.slice(5).trim())
            .join('\n');

        if (!payload) {
            return null;
        }

        return JSON.parse(payload) as WorkflowStreamEvent;
    }

    // ==========================================================================
    // MCP Server Direct Communication
    // ==========================================================================

    /**
     * List available MCP tools
     */
    getMCPTools(): Observable<MCPToolInfo[]> {
        return new Observable<MCPToolInfo[]>((subscriber) => {
            this.callMCP('tools/list', {}).subscribe({
                next: (result) => subscriber.next((result as { tools: MCPToolInfo[] }).tools ?? []),
                error: (err) => subscriber.error(err),
                complete: () => subscriber.complete(),
            });
        });
    }

    /**
     * List available MCP resources
     */
    getMCPResources(): Observable<MCPResourceInfo[]> {
        return new Observable<MCPResourceInfo[]>((subscriber) => {
            this.callMCP('resources/list', {}).subscribe({
                next: (result) => subscriber.next((result as { resources: MCPResourceInfo[] }).resources ?? []),
                error: (err) => subscriber.error(err),
                complete: () => subscriber.complete(),
            });
        });
    }

    /**
     * Run data quality check on a table
     */
    runDataQualityCheck(tableName: string, checks?: string[]): Observable<DataQualityResponse> {
        const args: Record<string, unknown> = { table_name: tableName };
        if (checks) {
            args['checks'] = JSON.stringify(checks);
        }
        return this.callMCPTool<DataQualityResponse>('data_quality_check', args);
    }

    /**
     * Analyze database schema
     */
    analyzeSchema(schemaDefinition: string): Observable<SchemaAnalysisResponse> {
        return this.callMCPTool<SchemaAnalysisResponse>('schema_analysis', {
            schema_definition: schemaDefinition,
        });
    }

    /**
     * Profile data in a table
     */
    profileData(tableName: string, columns?: string[]): Observable<DataProfilingResponse> {
        const args: Record<string, unknown> = { table_name: tableName };
        if (columns) {
            args['columns'] = JSON.stringify(columns);
        }
        return this.callMCPTool<DataProfilingResponse>('data_profiling', args);
    }

    /**
     * Detect anomalies in a column
     */
    detectAnomalies(tableName: string, column: string, method = 'zscore'): Observable<AnomalyDetectionResponse> {
        return this.callMCPTool<AnomalyDetectionResponse>('anomaly_detection', {
            table_name: tableName,
            column,
            method,
        });
    }

    /**
     * Chat with AI (PII-aware routing)
     * Returns response with routing metadata showing which backend was used
     */
    aiChat(messages: ChatMessage[], context?: { table_name?: string; data_class?: string }): Observable<AIChatResponse> {
        const args: Record<string, unknown> = {
            messages: JSON.stringify(messages.map((m) => ({ role: m.role, content: m.content }))),
        };
        if (context?.table_name) {
            args['table_name'] = context.table_name;
        }
        if (context?.data_class) {
            args['data_class'] = context.data_class;
        }
        return this.callMCPTool<AIChatResponse>('ai_chat', args);
    }

    /**
     * Index schema into KùzuDB graph
     */
    indexSchema(
        schema: { tables: Array<{ name: string; columns: Array<{ name: string; type: string }>; foreign_keys?: Array<{ column: string; ref_table: string; ref_column: string }> }> },
        checks?: Array<{ table: string; check_type: string; status: string; score: number; columns?: string[] }>,
    ): Observable<{ tables_indexed: number; columns_indexed: number; fks_indexed: number; checks_indexed: number }> {
        const args: Record<string, unknown> = {
            schema_definition: JSON.stringify(schema),
        };
        if (checks) {
            args['checks'] = JSON.stringify(checks);
        }
        return this.callMCPTool(args['schema_definition'] as string, args);
    }

    /**
     * Query the KùzuDB graph
     */
    queryGraph(cypher: string, params?: Record<string, unknown>): Observable<{ rows: Array<Record<string, unknown>>; row_count: number }> {
        const args: Record<string, unknown> = { cypher };
        if (params) {
            args['params'] = JSON.stringify(params);
        }
        return this.callMCPTool('kuzu_query', args);
    }

    /**
     * Query Mangle governance rules
     */
    queryMangle(predicate: string, args?: unknown[]): Observable<{ predicate: string; results: unknown[] }> {
        const mcpArgs: Record<string, unknown> = { predicate };
        if (args) {
            mcpArgs['args'] = JSON.stringify(args);
        }
        return this.callMCPTool('mangle_query', mcpArgs);
    }

    /**
     * Check MCP server health
     */
    mcpHealth(): Observable<{ status: string; service: string; auth_enabled: boolean }> {
        return this.http.get<{ status: string; service: string; auth_enabled: boolean }>(`${this.mcpBase}/health`);
    }

    /**
     * Call an MCP tool and return raw result (Promise-based for async/await usage).
     * Returns the raw MCP response with content array.
     */
    async callMcpTool(toolName: string, args: Record<string, unknown>): Promise<{ content: Array<{ type: string; text: string }> }> {
        const response = await fetch(`${this.mcpBase}/mcp`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                jsonrpc: '2.0',
                id: 1,
                method: 'tools/call',
                params: { name: toolName, arguments: args },
            }),
        });

        if (!response.ok) {
            throw new Error(`MCP call failed: HTTP ${response.status}`);
        }

        const data = await response.json();
        if (data.error) {
            throw new Error(data.error.message);
        }

        return data.result as { content: Array<{ type: string; text: string }> };
    }

    // ==========================================================================
    // Private MCP helpers
    // ==========================================================================

    private callMCP<T>(method: string, params: Record<string, unknown>): Observable<T> {
        return this.http.post<{ jsonrpc: string; id: number; result?: T; error?: { code: number; message: string } }>(`${this.mcpBase}/mcp`, {
            jsonrpc: '2.0',
            id: 1,
            method,
            params,
        }).pipe(
            map((response) => {
                if (response.error) {
                    throw new Error(response.error.message);
                }
                return response.result as T;
            }),
        );
    }

    private callMCPTool<T>(toolName: string, args: Record<string, unknown>): Observable<T> {
        return this.callMCP<{ content: Array<{ type: string; text: string }> }>('tools/call', {
            name: toolName,
            arguments: args,
        }).pipe(
            map((result) => {
                const text = result.content?.[0]?.text ?? '{}';
                return JSON.parse(text) as T;
            }),
        );
    }
}

// Import map for RxJS operators
import { map } from 'rxjs/operators';
