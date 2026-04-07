/**
 * IntentRouter — TypeScript port of ai-core-streaming/openai/router.py MeshRouter.
 *
 * Priority order:
 *   1. Forced header (X-Mesh-Force)
 *   2. Service-ID policy map
 *   3. Security class
 *   4. Model alias (confidential → local model)
 *   5. Model name → backend map
 *   6. Content keyword analysis
 *   7. Default → aicore-streaming
 */
export type RouteBackend = 'blocked' | 'vllm' | 'pal' | 'rag' | 'aicore-streaming';
export interface RouteDecision {
    backend: RouteBackend;
    reason: string;
    endpoint?: string;
}
export interface IntentRouterConfig {
    /** vLLM endpoint (confidential route) */
    vllmEndpoint?: string;
    /** ai-core-pal MCP endpoint (analytics route) */
    palEndpoint?: string;
    /** ai-core-streaming MCP endpoint (default route) */
    mcpEndpoint?: string;
    /** Custom keyword overrides for PAL detection */
    palKeywords?: string[];
    /** Custom keyword overrides for confidential detection */
    confidentialKeywords?: string[];
}
export declare class IntentRouter {
    private readonly vllmEndpoint;
    private readonly palEndpoint;
    private readonly mcpEndpoint;
    private readonly palKeywords;
    private readonly confidentialKeywords;
    constructor(config?: IntentRouterConfig);
    /**
     * Classify a request and return a routing decision.
     *
     * @param message - The user message text to analyse.
     * @param options - Optional routing hints (model, serviceId, securityClass, forceBackend).
     */
    classify(message: string, options?: {
        model?: string;
        serviceId?: string;
        securityClass?: string;
        forceBackend?: RouteBackend;
        enableRag?: boolean;
    }): RouteDecision;
    private endpointFor;
    private containsKeyword;
}
//# sourceMappingURL=intent-router.d.ts.map