import type { PipelineExecutionData } from './pipeline-execution-data.js';
/**
 * Representation of the 'GetPipelineExecutions' schema.
 */
export type GetPipelineExecutions = {
    /**
     * @example 2
     */
    count?: number;
    resources?: PipelineExecutionData[];
} & Record<string, any>;
//# sourceMappingURL=get-pipeline-executions.d.ts.map