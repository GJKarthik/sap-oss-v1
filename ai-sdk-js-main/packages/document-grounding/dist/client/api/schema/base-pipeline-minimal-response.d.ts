import type { PipelineExecutionStatus } from './pipeline-execution-status.js';
/**
 * Representation of the 'BasePipelineMinimalResponse' schema.
 */
export type BasePipelineMinimalResponse = {
    /**
     * @example "uuid"
     */
    id: string;
    status: PipelineExecutionStatus;
} & Record<string, any>;
//# sourceMappingURL=base-pipeline-minimal-response.d.ts.map