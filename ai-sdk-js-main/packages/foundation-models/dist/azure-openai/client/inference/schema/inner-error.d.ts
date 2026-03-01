import type { AzureOpenAiInnerErrorCode } from './inner-error-code.js';
import type { AzureOpenAiContentFilterPromptResults } from './content-filter-prompt-results.js';
/**
 * Inner error with additional details.
 */
export type AzureOpenAiInnerError = {
    code?: AzureOpenAiInnerErrorCode;
    content_filter_results?: AzureOpenAiContentFilterPromptResults;
} & Record<string, any>;
//# sourceMappingURL=inner-error.d.ts.map