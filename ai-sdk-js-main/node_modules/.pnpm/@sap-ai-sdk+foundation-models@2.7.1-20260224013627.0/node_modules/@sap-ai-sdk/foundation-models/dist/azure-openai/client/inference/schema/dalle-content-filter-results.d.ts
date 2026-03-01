import type { AzureOpenAiContentFilterSeverityResult } from './content-filter-severity-result.js';
/**
 * Information about the content filtering results.
 */
export type AzureOpenAiDalleContentFilterResults = {
    sexual?: AzureOpenAiContentFilterSeverityResult;
    violence?: AzureOpenAiContentFilterSeverityResult;
    hate?: AzureOpenAiContentFilterSeverityResult;
    self_harm?: AzureOpenAiContentFilterSeverityResult;
} & Record<string, any>;
//# sourceMappingURL=dalle-content-filter-results.d.ts.map