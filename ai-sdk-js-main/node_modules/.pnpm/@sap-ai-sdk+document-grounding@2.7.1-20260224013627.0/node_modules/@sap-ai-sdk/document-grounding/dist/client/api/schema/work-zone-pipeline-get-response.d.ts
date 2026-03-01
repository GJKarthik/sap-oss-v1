import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'WorkZonePipelineGetResponse' schema.
 */
export type WorkZonePipelineGetResponse = BasePipelineResponse & {
    type?: 'WorkZone';
    metadata: MetaData;
} & Record<string, any>;
//# sourceMappingURL=work-zone-pipeline-get-response.d.ts.map