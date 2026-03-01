import type { BasePipelineMinimalResponse } from './base-pipeline-minimal-response.js';
import type { MSSharePointConfigurationMinimal } from './ms-share-point-configuration-minimal.js';
/**
 * Representation of the 'MSSharePointPipelineMinimalResponse' schema.
 */
export type MSSharePointPipelineMinimalResponse = BasePipelineMinimalResponse & {
    type: 'MSSharePoint';
    configuration: MSSharePointConfigurationMinimal;
    /**
     * @example true
     */
    metadata?: boolean;
} & Record<string, any>;
//# sourceMappingURL=ms-share-point-pipeline-minimal-response.d.ts.map