// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * IntentRouter — Production AI Routing Gateway.
 *
 * Routes queries based on privacy and data type:
 * - Metadata / Public / Internal -> AI Core (Anthropic Claude 3.5)
 * - Private / Confidential / Business -> Local vLLM TurboQuant
 *
 * Priority order:
 *   1. Forced header (X-Mesh-Force)
 *   2. Service-ID policy map
 *   3. Security class
 *   4. Model alias (confidential → local model)
 *   5. Model name → backend map
 *   6. Content keyword analysis
 *   7. Default → aicore-anthropic
 */

// =============================================================================
// Types
// =============================================================================

export type RouteBackend = 'blocked' | 'vllm' | 'pal' | 'rag' | 'aicore-anthropic';

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
  /** AI Core Anthropic proxy endpoint (default route) */
  aicoreEndpoint?: string;
  /** Custom keyword overrides for PAL detection */
  palKeywords?: string[];
  /** Custom keyword overrides for confidential detection */
  confidentialKeywords?: string[];
}

// =============================================================================
// Default Endpoints — must be set via environment variables in production.
// =============================================================================

const BLOCKED_HOST_PREFIXES_IR = ['169.254.', '100.100.', 'fd00:', '::1'];

function _irSafeEnvUrl(envVar: string, localFallback: string): string {
  const raw = (process.env[envVar] ?? '').trim();
  const value = raw || localFallback;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return localFallback;
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) return localFallback;
  const host = parsed.hostname;
  for (const prefix of BLOCKED_HOST_PREFIXES_IR) {
    if (host.startsWith(prefix)) return localFallback;
  }
  return value.replace(/\/$/, '');
}

const DEFAULT_ENDPOINTS: Record<string, string> = {
  vllm:             _irSafeEnvUrl('VLLM_ENDPOINT',             'http://localhost:9180'),
  pal:              _irSafeEnvUrl('PAL_ENDPOINT',              'http://localhost:9170'),
  'aicore-anthropic': _irSafeEnvUrl('AICORE_ANTHROPIC_ENDPOINT', 'http://localhost:8080'),
};

/** Service-ID → backend mapping */
const SERVICE_ROUTING: Record<string, RouteBackend> = {
  'data-cleaning-copilot': 'vllm',
  'gen-ai-toolkit-hana': 'vllm',
  'ai-core-pal': 'pal',
  'langchain-hana': 'vllm',
  'odata-vocabularies': 'aicore-anthropic',
  'ui5-webcomponents-ngx': 'aicore-anthropic',
  'world-monitor': 'aicore-anthropic',
  'sac-ai-widget': 'aicore-anthropic',
};

/** Security class → backend mapping */
const SECURITY_ROUTING: Record<string, RouteBackend> = {
  public: 'aicore-anthropic',
  internal: 'aicore-anthropic',
  confidential: 'vllm',
  restricted: 'blocked',
};

/** Model name → backend */
const MODEL_BACKEND: Record<string, RouteBackend> = {
  'Qwen/Qwen3.5-35B-A3B-FP8': 'vllm',
  'claude-3-5-sonnet-20240620': 'aicore-anthropic',
};

/**
 * Keywords that indicate confidential data — route to vLLM (on-premise).
 */
const DEFAULT_CONFIDENTIAL_KEYWORDS: string[] = [
  'customer', 'order', 'invoice', 'contract', 'supplier',
  'business partner', 'cds entity', 'cap service',
  'revenue', 'profit', 'cost', 'budget', 'forecast',
  'personal', 'private', 'confidential',
  'salary', 'ssn', 'credit_card', 'password',
  'banking', 'nfrp', 'client', 'transaction'
];

const RESTRICTED_KEYWORDS: string[] = ['restricted', 'classified', 'secret'];

const DEFAULT_PAL_KEYWORDS: string[] = [
  'forecast', 'predict', 'regression', 'classification', 'cluster', 'clustering',
  'anomaly', 'detect', 'arima', 'kmeans', 'k-means', 'segment', 'segmentation',
  'time series', 'timeseries', 'outlier', 'pal algorithm', 'hana pal',
];

export class IntentRouter {
  private readonly vllmEndpoint: string;
  private readonly palEndpoint: string;
  private readonly aicoreEndpoint: string;
  private readonly palKeywords: string[];
  private readonly confidentialKeywords: string[];

  constructor(config: IntentRouterConfig = {}) {
    this.vllmEndpoint = config.vllmEndpoint ?? DEFAULT_ENDPOINTS['vllm'];
    this.palEndpoint = config.palEndpoint ?? DEFAULT_ENDPOINTS['pal'];
    this.aicoreEndpoint = config.aicoreEndpoint ?? DEFAULT_ENDPOINTS['aicore-anthropic'];
    this.palKeywords = config.palKeywords ?? DEFAULT_PAL_KEYWORDS;
    this.confidentialKeywords = config.confidentialKeywords ?? DEFAULT_CONFIDENTIAL_KEYWORDS;
  }

  classify(
    message: string,
    options: {
      model?: string;
      serviceId?: string;
      securityClass?: string;
      forceBackend?: RouteBackend;
      enableRag?: boolean;
    } = {}
  ): RouteDecision {
    const { model, serviceId, securityClass, forceBackend, enableRag } = options;
    const content = message.toLowerCase();

    if (forceBackend) {
      if (forceBackend === 'blocked') return { backend: 'blocked', reason: 'Forced block via header' };
      return { backend: forceBackend, reason: `Forced routing via header: ${forceBackend}`, endpoint: this.endpointFor(forceBackend) };
    }

    if (serviceId && SERVICE_ROUTING[serviceId]) {
      const backend = SERVICE_ROUTING[serviceId];
      return { backend, reason: `Service policy: ${serviceId} → ${backend}`, endpoint: this.endpointFor(backend) };
    }

    if (securityClass && SECURITY_ROUTING[securityClass]) {
      const backend = SECURITY_ROUTING[securityClass];
      if (backend === 'blocked') return { backend: 'blocked', reason: `Security class '${securityClass}' is restricted` };
      return { backend, reason: `Security class: ${securityClass} → ${backend}`, endpoint: this.endpointFor(backend) };
    }

    if (model && MODEL_BACKEND[model]) {
      const backend = MODEL_BACKEND[model];
      return { backend, reason: `Model routing: ${model} → ${backend}`, endpoint: this.endpointFor(backend) };
    }

    if (this.containsKeyword(content, RESTRICTED_KEYWORDS)) {
      return { backend: 'blocked', reason: 'Restricted keywords detected in content' };
    }

    if (this.containsKeyword(content, this.confidentialKeywords)) {
      return { backend: 'vllm', reason: 'Confidential keywords detected in content', endpoint: this.vllmEndpoint };
    }

    if (this.containsKeyword(content, this.palKeywords)) {
      return { backend: 'pal', reason: 'Analytics/PAL keywords detected in content', endpoint: this.palEndpoint };
    }

    if (enableRag) return { backend: 'rag', reason: 'HANA RAG enabled for this service' };

    return {
      backend: 'aicore-anthropic',
      reason: 'Default routing: public/internal data → AI Core Anthropic',
      endpoint: this.aicoreEndpoint,
    };
  }

  private endpointFor(backend: RouteBackend): string | undefined {
    switch (backend) {
      case 'vllm': return this.vllmEndpoint;
      case 'pal': return this.palEndpoint;
      case 'aicore-anthropic': return this.aicoreEndpoint;
      default: return undefined;
    }
  }

  private containsKeyword(content: string, keywords: string[]): boolean {
    return keywords.some(kw => content.includes(kw));
  }
}
