import type { PipelineExecutionStatus } from './pipeline-execution-status.js';
/**
 * Representation of the 'PipelineExecutionData' schema.
 */
export type PipelineExecutionData = {
    /**
     * @example "uuid"
     */
    id?: string;
    status?: PipelineExecutionStatus;
    /**
     * @example "2024-02-15T12:45:00Z"
     * Pattern: "^$|^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$".
     */
    createdAt?: string | null;
    /**
     * @example "2024-02-15T12:45:00Z"
     * Pattern: "^$|^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$".
     */
    modifiedAt?: string | null;
} & Record<string, any>;
//# sourceMappingURL=pipeline-execution-data.d.ts.map