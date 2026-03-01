import type { BasePipelineMinimalResponse } from './base-pipeline-minimal-response.js';
import type { S3ConfigurationMinimal } from './s-3-configuration-minimal.js';
/**
 * Representation of the 'S3PipelineMinimalResponse' schema.
 */
export type S3PipelineMinimalResponse = BasePipelineMinimalResponse & {
    type: 'S3';
    configuration: S3ConfigurationMinimal;
    /**
     * @example true
     */
    metadata?: boolean;
} & Record<string, any>;
//# sourceMappingURL=s-3-pipeline-minimal-response.d.ts.map