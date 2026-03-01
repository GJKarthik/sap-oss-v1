import type { MSSharePointConfiguration } from './ms-share-point-configuration.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'MSSharePointPipelineCreateRequest' schema.
 */
export type MSSharePointPipelineCreateRequest = {
    type: 'MSSharePoint';
    configuration: MSSharePointConfiguration;
    metadata?: MetaData;
} & Record<string, any>;
//# sourceMappingURL=ms-share-point-pipeline-create-request.d.ts.map