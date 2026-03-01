import type { SharePointConfig } from './share-point-config.js';
/**
 * Representation of the 'MSSharePointConfiguration' schema.
 */
export type MSSharePointConfiguration = {
    /**
     * @example "generic-secret-name"
     */
    destination: string;
    sharePoint: SharePointConfig;
    /**
     * @example "0 3 * * *"
     */
    cronExpression?: string;
} & Record<string, any>;
//# sourceMappingURL=ms-share-point-configuration.d.ts.map