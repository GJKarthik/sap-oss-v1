import type { OrchestrationConfig } from './orchestration-config.js';
/**
 * Representation of the 'OrchestrationConfigPostRequest' schema.
 */
export type OrchestrationConfigPostRequest = {
    /**
     * Max Length: 120.
     * Pattern: "^[a-zA-Z0-9_-]+$".
     */
    name: string;
    /**
     * Max Length: 10.
     * Pattern: "^[a-zA-Z0-9._-]+$".
     */
    version: string;
    /**
     * Max Length: 120.
     * Pattern: "^[a-zA-Z0-9_-]+$".
     */
    scenario: string;
    spec: OrchestrationConfig;
} & Record<string, any>;
//# sourceMappingURL=orchestration-config-post-request.d.ts.map