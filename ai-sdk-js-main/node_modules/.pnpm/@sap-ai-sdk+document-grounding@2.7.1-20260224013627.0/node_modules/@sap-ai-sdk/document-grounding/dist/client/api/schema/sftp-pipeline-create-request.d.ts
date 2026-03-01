import type { SFTPConfiguration } from './sftp-configuration.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'SFTPPipelineCreateRequest' schema.
 */
export type SFTPPipelineCreateRequest = {
    type: 'SFTP';
    configuration: SFTPConfiguration;
    metadata?: MetaData;
} & Record<string, any>;
//# sourceMappingURL=sftp-pipeline-create-request.d.ts.map