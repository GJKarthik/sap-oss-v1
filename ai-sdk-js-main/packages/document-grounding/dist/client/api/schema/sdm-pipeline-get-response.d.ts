import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'SDMPipelineGetResponse' schema.
 */
export type SDMPipelineGetResponse = BasePipelineResponse & {
    type?: 'SDM';
    metadata: MetaData;
} & Record<string, any>;
//# sourceMappingURL=sdm-pipeline-get-response.d.ts.map