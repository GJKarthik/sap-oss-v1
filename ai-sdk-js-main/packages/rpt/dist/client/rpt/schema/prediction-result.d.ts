/**
 * A single prediction result for a single column in a single row.
 */
export type PredictionResult = {
    /**
     * The predicted value for the column.
     */
    prediction: string | number;
    /**
     * The confidence of the prediction (currently not provided).
     */
    confidence?: number | null;
} & Record<string, any>;
//# sourceMappingURL=prediction-result.d.ts.map