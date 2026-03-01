import type { DetailsErrorResponse } from './details-error-response.js';
/**
 * Representation of the 'ApiError' schema.
 */
export type ApiError = {
    /**
     * Descriptive error code (not http status code).
     */
    code: string;
    /**
     * plaintext error description
     */
    message: string;
    /**
     * id of individual request
     */
    requestId?: string;
    /**
     * url that has been called
     */
    target?: string;
    details?: DetailsErrorResponse[];
} & Record<string, any>;
//# sourceMappingURL=api-error.d.ts.map