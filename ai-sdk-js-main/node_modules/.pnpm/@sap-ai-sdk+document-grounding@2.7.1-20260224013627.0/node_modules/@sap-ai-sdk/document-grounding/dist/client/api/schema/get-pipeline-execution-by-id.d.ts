import type { PipelineExecutionStatus } from './pipeline-execution-status.js';
/**
 * Representation of the 'GetPipelineExecutionById' schema.
 */
export type GetPipelineExecutionById = {
    /**
     * @example "uuid"
     */
    id?: string;
    /**
     * @example "2024-02-15T12:45:00Z"
     */
    createdAt?: string;
    /**
     * @example "2024-02-15T12:45:00Z"
     */
    modifiedAt?: string;
    status?: PipelineExecutionStatus;
} & Record<string, any>;
//# sourceMappingURL=get-pipeline-execution-by-id.d.ts.map