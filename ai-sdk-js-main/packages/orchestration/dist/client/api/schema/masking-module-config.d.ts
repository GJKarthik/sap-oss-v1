import type { MaskingProviderConfig } from './masking-provider-config.js';
/**
 * Representation of the 'MaskingModuleConfig' schema.
 */
export type MaskingModuleConfig = {
    /**
     * List of masking service providers
     * Min Items: 1.
     */
    providers: MaskingProviderConfig[];
} | {
    /**
     * List of masking service providers. **DEPRECATED**:  will be removed Sept 15, 2026. Use `providers` property instead.
     * @deprecated
     * Min Items: 1.
     */
    masking_providers: MaskingProviderConfig[];
};
//# sourceMappingURL=masking-module-config.d.ts.map