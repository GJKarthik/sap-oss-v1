import type { BasePipelineMinimalResponse } from './base-pipeline-minimal-response.js';
/**
 * Representation of the 'WorkZonePipelineMinimalResponse' schema.
 */
export type WorkZonePipelineMinimalResponse = BasePipelineMinimalResponse & {
    type: 'WorkZone';
    /**
     * @example true
     */
    metadata?: boolean;
} & Record<string, any>;
//# sourceMappingURL=work-zone-pipeline-minimal-response.d.ts.map