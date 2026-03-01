import type { ValidationError } from './validation-error.js';
/**
 * Representation of the 'HTTPValidationError' schema.
 */
export type HTTPValidationError = {
    detail?: ValidationError[];
} & Record<string, any>;
//# sourceMappingURL=http-validation-error.d.ts.map