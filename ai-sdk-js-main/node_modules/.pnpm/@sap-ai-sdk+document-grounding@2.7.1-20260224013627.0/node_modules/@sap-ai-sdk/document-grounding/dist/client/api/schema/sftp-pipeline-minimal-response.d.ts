import type { BasePipelineMinimalResponse } from './base-pipeline-minimal-response.js';
import type { SFTPConfigurationMinimal } from './sftp-configuration-minimal.js';
/**
 * Representation of the 'SFTPPipelineMinimalResponse' schema.
 */
export type SFTPPipelineMinimalResponse = BasePipelineMinimalResponse & {
    type: 'SFTP';
    configuration: SFTPConfigurationMinimal;
    /**
     * @example true
     */
    metadata?: boolean;
} & Record<string, any>;
//# sourceMappingURL=sftp-pipeline-minimal-response.d.ts.map