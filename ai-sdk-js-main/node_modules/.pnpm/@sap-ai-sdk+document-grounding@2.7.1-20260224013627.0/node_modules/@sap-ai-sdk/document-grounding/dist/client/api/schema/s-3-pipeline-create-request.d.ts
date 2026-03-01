import type { S3Configuration } from './s-3-configuration.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'S3PipelineCreateRequest' schema.
 */
export type S3PipelineCreateRequest = {
    type: 'S3';
    configuration: S3Configuration;
    metadata?: MetaData;
} & Record<string, any>;
//# sourceMappingURL=s-3-pipeline-create-request.d.ts.map