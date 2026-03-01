import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { MSSharePointConfigurationGetResponse } from './ms-share-point-configuration-get-response.js';
/**
 * Representation of the 'MSSharePointPipelineGetResponse' schema.
 */
export type MSSharePointPipelineGetResponse = BasePipelineResponse & {
    type?: 'MSSharePoint';
    configuration: MSSharePointConfigurationGetResponse;
} & Record<string, any>;
//# sourceMappingURL=ms-share-point-pipeline-get-response.d.ts.map