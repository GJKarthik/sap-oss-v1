import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { SFTPConfiguration } from './sftp-configuration.js';
/**
 * Representation of the 'SFTPPipelineGetResponse' schema.
 */
export type SFTPPipelineGetResponse = BasePipelineResponse & {
    type?: 'SFTP';
    configuration: SFTPConfiguration;
} & Record<string, any>;
//# sourceMappingURL=sftp-pipeline-get-response.d.ts.map