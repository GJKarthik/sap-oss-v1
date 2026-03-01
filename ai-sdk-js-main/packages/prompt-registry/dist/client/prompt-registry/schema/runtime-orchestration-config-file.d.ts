import type { OrchestrationConfig } from './orchestration-config.js';
/**
 * Representation of the 'RuntimeOrchestrationConfigFile' schema.
 */
export type RuntimeOrchestrationConfigFile = {
    apiVersion?: string;
    kind?: string;
    metadata?: {
        name?: string;
        version?: string;
        scenario?: string;
    } & Record<string, any>;
    spec?: OrchestrationConfig;
} & Record<string, any>;
//# sourceMappingURL=runtime-orchestration-config-file.d.ts.map