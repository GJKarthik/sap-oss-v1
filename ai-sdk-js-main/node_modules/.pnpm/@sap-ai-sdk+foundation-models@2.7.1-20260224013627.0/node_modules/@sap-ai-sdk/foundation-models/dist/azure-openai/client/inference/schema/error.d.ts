import type { AzureOpenAiErrorBase } from './error-base.js';
import type { AzureOpenAiInnerError } from './inner-error.js';
/**
 * Representation of the 'AzureOpenAiError' schema.
 */
export type AzureOpenAiError = AzureOpenAiErrorBase & {
    param?: string;
    type?: string;
    inner_error?: AzureOpenAiInnerError;
} & Record<string, any>;
//# sourceMappingURL=error.d.ts.map