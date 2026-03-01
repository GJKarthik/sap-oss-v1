/**
 * Output status for prediction requests.
 */
export type PredictResponseStatus = {
    /**
     * Status code (zero means success, other status codes indicate warnings)
     */
    code: number;
    /**
     * Status message, either "ok" or contains a warning / more information.
     */
    message: string;
} & Record<string, any>;
//# sourceMappingURL=predict-response-status.d.ts.map