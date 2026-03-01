import type { AzureOpenAiErrorBase } from './error-base.js';
import type { AzureOpenAiDalleInnerError } from './dalle-inner-error.js';
/**
 * Representation of the 'AzureOpenAiDalleError' schema.
 */
export type AzureOpenAiDalleError = AzureOpenAiErrorBase & {
    param?: string;
    type?: string;
    inner_error?: AzureOpenAiDalleInnerError;
} & Record<string, any>;
//# sourceMappingURL=dalle-error.d.ts.map