import type { AzureOpenAiContentFilterPromptResults } from './content-filter-prompt-results.js';
/**
 * Content filtering results for a single prompt in the request.
 */
export type AzureOpenAiPromptFilterResult = {
    prompt_index?: number;
    content_filter_results?: AzureOpenAiContentFilterPromptResults;
} & Record<string, any>;
//# sourceMappingURL=prompt-filter-result.d.ts.map