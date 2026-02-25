import type { OrchestrationConfig } from './orchestration-config.js';
/**
 * Representation of the 'OrchestrationConfigResource' schema.
 */
export type OrchestrationConfigResource = {
    /**
     * Format: "uuid".
     */
    id?: string;
    name?: string;
    version?: string;
    scenario?: string;
    /**
     * Format: "timestamp".
     */
    creation_timestamp?: string;
    managed_by?: string;
    is_version_head?: boolean;
    resource_group_id?: string;
    spec?: OrchestrationConfig;
} & Record<string, any>;
//# sourceMappingURL=orchestration-config-resource.d.ts.map