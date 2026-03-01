import type { AzureOpenAiInnerErrorCode } from './inner-error-code.js';
import type { AzureOpenAiDalleFilterResults } from './dalle-filter-results.js';
/**
 * Inner error with additional details.
 */
export type AzureOpenAiDalleInnerError = {
    code?: AzureOpenAiInnerErrorCode;
    content_filter_results?: AzureOpenAiDalleFilterResults;
    /**
     * The prompt that was used to generate the image, if there was any revision to the prompt.
     */
    revised_prompt?: string;
} & Record<string, any>;
//# sourceMappingURL=dalle-inner-error.d.ts.map