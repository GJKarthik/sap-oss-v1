import type { AzureOpenAiContentFilterResultBase } from './content-filter-result-base.js';
/**
 * Representation of the 'AzureOpenAiContentFilterSeverityResult' schema.
 */
export type AzureOpenAiContentFilterSeverityResult = AzureOpenAiContentFilterResultBase & {
    severity: 'safe' | 'low' | 'medium' | 'high';
} & Record<string, any>;
//# sourceMappingURL=content-filter-severity-result.d.ts.map