import type { IncludePathsArray } from './include-paths-array.js';
/**
 * Representation of the 'SFTPConfiguration' schema.
 */
export type SFTPConfiguration = {
    /**
     * @example "generic-secret-name"
     */
    destination: string;
    sftp?: {
        includePaths?: IncludePathsArray;
    } & Record<string, any>;
    /**
     * @example "0 3 * * *"
     */
    cronExpression?: string;
} & Record<string, any>;
//# sourceMappingURL=sftp-configuration.d.ts.map