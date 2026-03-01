import type { BasePipelineMinimalResponse } from './base-pipeline-minimal-response.js';
/**
 * Representation of the 'SDMPipelineMinimalResponse' schema.
 */
export type SDMPipelineMinimalResponse = BasePipelineMinimalResponse & {
    type: 'SDM';
    /**
     * @example true
     */
    metadata?: boolean;
} & Record<string, any>;
//# sourceMappingURL=sdm-pipeline-minimal-response.d.ts.map