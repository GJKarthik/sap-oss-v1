import type { PipelineExecutionStatus } from './pipeline-execution-status.js';
/**
 * Representation of the 'GetPipelineStatus' schema.
 */
export type GetPipelineStatus = {
    /**
     * @example "2024-02-15T12:45:00.000Z"
     * Pattern: "^$|^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$".
     */
    lastStarted?: string;
    /**
     * @example "2024-02-15T12:45:00.000Z"
     * Pattern: "^$|^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$".
     */
    createdAt?: string | null;
    /**
     * @example "2024-02-15T12:45:00.000Z"
     * Pattern: "^$|^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$".
     */
    lastCompletedAt?: string | null;
    status?: PipelineExecutionStatus;
} & Record<string, any>;
//# sourceMappingURL=get-pipeline-status.d.ts.map