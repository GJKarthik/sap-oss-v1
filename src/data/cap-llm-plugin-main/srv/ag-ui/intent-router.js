"use strict";
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.IntentRouter = void 0;
// =============================================================================
// Routing Tables (ported from MeshRouter)
// =============================================================================
const DEFAULT_BACKENDS = {
    'aicore-streaming': 'http://localhost:9190',
    vllm: 'http://localhost:9180',
    pal: 'http://localhost:8084',
};
/** Service-ID → backend mapping (mirrors MeshRouter.SERVICE_ROUTING) */
const SERVICE_ROUTING = {
    'data-cleaning-copilot': 'vllm',
    'gen-ai-toolkit-hana': 'vllm',
    'ai-core-pal': 'pal',
    'langchain-hana': 'vllm',
    'odata-vocabularies': 'aicore-streaming',
    'ui5-webcomponents-ngx': 'aicore-streaming',
    'world-monitor': 'aicore-streaming',
};
/** Security class → backend mapping */
const SECURITY_ROUTING = {
    public: 'aicore-streaming',
    internal: 'aicore-streaming',
    confidential: 'vllm',
    restricted: 'blocked',
};
/** Model name → backend (Qwen3.5 family only) */
const MODEL_BACKEND = {
    'Qwen/Qwen3.5-0.8B': 'vllm',
    'Qwen/Qwen3.5-9B': 'vllm',
    'Qwen/Qwen3.5-35B': 'vllm',
    // Short aliases
    'qwen3.5-0.8b': 'vllm',
    'qwen3.5-9b': 'vllm',
    'qwen3.5-35b': 'vllm',
};
/** Confidential model aliases → reroute to local Qwen3.5 vLLM model */
const MODEL_ALIASES = {
    'qwen3.5-confidential': 'Qwen/Qwen3.5-35B',
    'qwen3.5-0.8b-confidential': 'Qwen/Qwen3.5-0.8B',
    'qwen3.5-9b-confidential': 'Qwen/Qwen3.5-9B',
};
/** Keywords that indicate confidential data — route to vLLM */
const DEFAULT_CONFIDENTIAL_KEYWORDS = [
    'customer', 'personal', 'private', 'confidential',
    'salary', 'ssn', 'credit_card', 'password', 'secret',
];
/** Keywords indicating a restricted request — block entirely */
const RESTRICTED_KEYWORDS = [
    'restricted', 'classified', 'secret',
];
/** Keywords that indicate SAP HANA PAL analytics intent — route to ai-core-pal */
const DEFAULT_PAL_KEYWORDS = [
    'forecast', 'predict', 'regression', 'classification', 'cluster', 'clustering',
    'anomaly', 'detect', 'arima', 'kmeans', 'k-means', 'segment', 'segmentation',
    'time series', 'timeseries', 'outlier', 'pal algorithm', 'hana pal',
];
// =============================================================================
// IntentRouter
// =============================================================================
class IntentRouter {
    constructor(config = {}) {
        this.vllmEndpoint = config.vllmEndpoint ?? DEFAULT_BACKENDS['vllm'];
        this.palEndpoint = config.palEndpoint ?? DEFAULT_BACKENDS['pal'];
        this.mcpEndpoint = config.mcpEndpoint ?? DEFAULT_BACKENDS['aicore-streaming'];
        this.palKeywords = config.palKeywords ?? DEFAULT_PAL_KEYWORDS;
        this.confidentialKeywords = config.confidentialKeywords ?? DEFAULT_CONFIDENTIAL_KEYWORDS;
    }
    /**
     * Classify a request and return a routing decision.
     *
     * @param message - The user message text to analyse.
     * @param options - Optional routing hints (model, serviceId, securityClass, forceBackend).
     */
    classify(message, options = {}) {
        const { model, serviceId, securityClass, forceBackend, enableRag } = options;
        const content = message.toLowerCase();
        // 1. Forced backend
        if (forceBackend) {
            if (forceBackend === 'blocked') {
                return { backend: 'blocked', reason: 'Forced block via header' };
            }
            return {
                backend: forceBackend,
                reason: `Forced routing via header: ${forceBackend}`,
                endpoint: this.endpointFor(forceBackend),
            };
        }
        // 2. Service-ID policy
        if (serviceId && SERVICE_ROUTING[serviceId]) {
            const backend = SERVICE_ROUTING[serviceId];
            return {
                backend,
                reason: `Service policy: ${serviceId} → ${backend}`,
                endpoint: this.endpointFor(backend),
            };
        }
        // 3. Security class
        if (securityClass && SECURITY_ROUTING[securityClass]) {
            const backend = SECURITY_ROUTING[securityClass];
            if (backend === 'blocked') {
                return { backend: 'blocked', reason: `Security class '${securityClass}' is restricted` };
            }
            return {
                backend,
                reason: `Security class: ${securityClass} → ${backend}`,
                endpoint: this.endpointFor(backend),
            };
        }
        // 4. Model alias (confidential alias → vllm)
        if (model && MODEL_ALIASES[model]) {
            return {
                backend: 'vllm',
                reason: `Model alias: ${model} → ${MODEL_ALIASES[model]} (vllm)`,
                endpoint: this.vllmEndpoint,
            };
        }
        // 5. Model → backend map
        if (model && MODEL_BACKEND[model]) {
            const backend = MODEL_BACKEND[model];
            return {
                backend,
                reason: `Model routing: ${model} → ${backend}`,
                endpoint: this.endpointFor(backend),
            };
        }
        // 6a. Restricted content keywords — block
        if (this.containsKeyword(content, RESTRICTED_KEYWORDS)) {
            return { backend: 'blocked', reason: 'Restricted keywords detected in content' };
        }
        // 6b. Confidential content keywords → vllm
        if (this.containsKeyword(content, this.confidentialKeywords)) {
            return {
                backend: 'vllm',
                reason: 'Confidential keywords detected in content',
                endpoint: this.vllmEndpoint,
            };
        }
        // 6c. PAL analytics intent keywords → ai-core-pal
        if (this.containsKeyword(content, this.palKeywords)) {
            return {
                backend: 'pal',
                reason: 'Analytics/PAL keywords detected in content',
                endpoint: this.palEndpoint,
            };
        }
        // 6d. HANA RAG — if configured
        if (enableRag) {
            return {
                backend: 'rag',
                reason: 'HANA RAG enabled for this service',
            };
        }
        // 7. Default → ai-core-streaming MCP
        return {
            backend: 'aicore-streaming',
            reason: 'Default routing: public/internal data → aicore-streaming',
            endpoint: this.mcpEndpoint,
        };
    }
    endpointFor(backend) {
        switch (backend) {
            case 'vllm': return this.vllmEndpoint;
            case 'pal': return this.palEndpoint;
            case 'aicore-streaming': return this.mcpEndpoint;
            default: return undefined;
        }
    }
    containsKeyword(content, keywords) {
        return keywords.some(kw => content.includes(kw));
    }
}
exports.IntentRouter = IntentRouter;
//# sourceMappingURL=intent-router.js.map