/**
 * OpenAI-Compatible HTTP Server
 *
 * Provides full OpenAI API compatibility while routing to SAP AI Core.
 * Supports both OpenAI and Anthropic model formats.
 */
import { Express } from 'express';
interface AICoreConfig {
    clientId: string;
    clientSecret: string;
    authUrl: string;
    baseUrl: string;
    resourceGroup: string;
}
export interface ServerOptions {
    port?: number;
    config?: AICoreConfig;
    defaultChatModel?: string;
    defaultEmbeddingModel?: string;
    apiKey?: string;
}
export declare function createServer(options?: ServerOptions): Express;
export default createServer;
//# sourceMappingURL=server.d.ts.map