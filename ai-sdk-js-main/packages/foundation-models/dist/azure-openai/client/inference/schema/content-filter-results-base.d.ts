import type { AzureOpenAiContentFilterSeverityResult } from './content-filter-severity-result.js';
import type { AzureOpenAiContentFilterDetectedResult } from './content-filter-detected-result.js';
import type { AzureOpenAiErrorBase } from './error-base.js';
/**
 * Information about the content filtering results.
 */
export type AzureOpenAiContentFilterResultsBase = {
    sexual?: AzureOpenAiContentFilterSeverityResult;
    violence?: AzureOpenAiContentFilterSeverityResult;
    hate?: AzureOpenAiContentFilterSeverityResult;
    self_harm?: AzureOpenAiContentFilterSeverityResult;
    profanity?: AzureOpenAiContentFilterDetectedResult;
    error?: AzureOpenAiErrorBase;
} & Record<string, any>;
//# sourceMappingURL=content-filter-results-base.d.ts.map