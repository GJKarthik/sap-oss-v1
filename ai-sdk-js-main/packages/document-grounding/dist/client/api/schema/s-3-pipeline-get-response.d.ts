import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { S3Configuration } from './s-3-configuration.js';
/**
 * Representation of the 'S3PipelineGetResponse' schema.
 */
export type S3PipelineGetResponse = BasePipelineResponse & {
    type?: 'S3';
    configuration: S3Configuration;
} & Record<string, any>;
//# sourceMappingURL=s-3-pipeline-get-response.d.ts.map