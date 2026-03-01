/**
 * Representation of the 'BodyPredictParquet' schema.
 */
export type BodyPredictParquet = {
    /**
     * Parquet file containing the data
     * Format: "binary".
     */
    file: string;
    /**
     * JSON string for prediction_config
     */
    prediction_config: string;
    /**
     * Optional index column name
     */
    index_column?: string;
    /**
     * Whether to parse data types
     * Default: true.
     */
    parse_data_types?: boolean;
} & Record<string, any>;
//# sourceMappingURL=body-predict-parquet.d.ts.map