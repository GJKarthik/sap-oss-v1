import type { AzureOpenAiContentFilterDetectedResult } from './content-filter-detected-result.js';
/**
 * Representation of the 'AzureOpenAiContentFilterDetectedWithCitationResult' schema.
 */
export type AzureOpenAiContentFilterDetectedWithCitationResult = AzureOpenAiContentFilterDetectedResult & {
    citation?: {
        URL?: string;
        license?: string;
    } & Record<string, any>;
} & Record<string, any>;
//# sourceMappingURL=content-filter-detected-with-citation-result.d.ts.map