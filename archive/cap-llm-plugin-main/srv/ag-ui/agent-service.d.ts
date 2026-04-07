/**
 * AG-UI Agent Service
 *
 * Main orchestrator for the AG-UI protocol. Handles incoming requests,
 * emits AG-UI events via SSE, and coordinates LLM calls with UI generation.
 *
 * Routing (via IntentRouter):
 *   blocked          → 403, no LLM call
 *   vllm             → @sap-ai-sdk/vllm VllmChatClient
 *   pal              → PalClient → ai-core-pal MCP :8084
 *   rag              → HANAVectorStore + OrchestrationClient
 *   aicore-streaming → ai-core-streaming MCP :9190 stream_complete
 */
import type { ServerResponse } from 'http';
import { AgUiRunRequest, AgUiToolResultRequest, A2UiSchema } from './event-types';
import { ToolRegistry } from './tool-handler';
/** Agent service configuration */
export interface AgUiAgentConfig {
    chatModelName: string;
    uiModelName?: string;
    resourceGroup: string;
    enableRag?: boolean;
    ragTable?: string;
    ragEmbeddingColumn?: string;
    ragContentColumn?: string;
    embeddingModelName?: string;
    /** vLLM endpoint for confidential data route (default: http://localhost:9180) */
    vllmEndpoint?: string;
    /** vLLM model name to use (default: Qwen/Qwen3.5-35B) */
    vllmModel?: string;
    /** ai-core-pal MCP endpoint for analytics route (default: http://localhost:8084/mcp) */
    palEndpoint?: string;
    /** ai-core-streaming MCP endpoint for default route (default: http://localhost:9190/mcp) */
    mcpEndpoint?: string;
    /** Service identifier used for routing policy lookup */
    serviceId?: string;
    /** Security classification: public | internal | confidential | restricted */
    securityClass?: string;
    /** Additional confidential keywords beyond defaults */
    confidentialKeywords?: string[];
    /** Additional PAL analytics keywords beyond defaults */
    palKeywords?: string[];
}
/** Session state */
interface AgentSession {
    threadId: string;
    runId: string;
    messages: Array<{
        role: string;
        content: string;
    }>;
    currentSchema?: A2UiSchema;
    state: Record<string, unknown>;
    createdAt: number;
    lastActivityAt: number;
}
export declare class AgUiAgentService {
    private config;
    private schemaGenerator;
    private toolHandler;
    private intentRouter;
    private palClient;
    private sessions;
    private llmPlugin;
    constructor(config: AgUiAgentConfig, llmPlugin: unknown);
    getToolRegistry(): ToolRegistry;
    handleRunRequest(request: AgUiRunRequest, httpRes: ServerResponse): Promise<void>;
    handleToolResult(request: AgUiToolResultRequest): Promise<void>;
    streamTextResponse(messages: Array<{
        role: string;
        content: string;
    }>, httpRes: ServerResponse, threadId: string, runId: string): Promise<void>;
    getSession(threadId: string): AgentSession | undefined;
    clearSession(threadId: string): void;
    private generateSchemaViaVllm;
    private generateSchemaViaPal;
    private generateSchemaWithRag;
    private generateSchemaViaAicoreStreaming;
    private generateSchemaDirectly;
    private writeEvent;
    private generateId;
}
export declare function createAgUiServiceHandler(config: AgUiAgentConfig): {
    new (): {
        [x: string]: any;
        agent: AgUiAgentService;
        init(): Promise<void>;
        run(req: any): Promise<void>;
        toolResult(req: any): Promise<{
            success: boolean;
        }>;
        getSession(req: any): Promise<AgentSession | null>;
        clearSession(req: any): Promise<{
            success: boolean;
        }>;
        getAgent(): AgUiAgentService;
    };
    [x: string]: any;
};
export {};
//# sourceMappingURL=agent-service.d.ts.map