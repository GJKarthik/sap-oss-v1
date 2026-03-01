/**
 * SAP AI SDK MCP Server
 *
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools, resources, and prompts for SAP AI Core operations.
 */
import * as http from 'http';
interface MCPRequest {
    jsonrpc: '2.0';
    id: string | number;
    method: string;
    params?: Record<string, unknown>;
}
interface MCPResponse {
    jsonrpc: '2.0';
    id: string | number;
    result?: unknown;
    error?: {
        code: number;
        message: string;
        data?: unknown;
    };
}
declare class MCPServer {
    private tools;
    private resources;
    private prompts;
    private toolHandlers;
    private facts;
    constructor();
    private registerTools;
    private registerResources;
    private registerPrompts;
    private initializeFacts;
    private getFederatedMcpEndpoints;
    private handleChatTool;
    private handleEmbedTool;
    private handleVectorSearchTool;
    private handleListDeploymentsTool;
    private handleOrchestrationTool;
    private handleMangleQueryTool;
    handleRequest(request: MCPRequest): Promise<MCPResponse>;
    private handleInitialize;
    private handleToolsList;
    private handleToolsCall;
    private handleResourcesList;
    private handleResourcesRead;
    private handlePromptsList;
    private handlePromptsGet;
    private getMangleRules;
}
declare const httpServer: http.Server<typeof http.IncomingMessage, typeof http.ServerResponse>;
export { MCPServer, httpServer };
//# sourceMappingURL=server.d.ts.map