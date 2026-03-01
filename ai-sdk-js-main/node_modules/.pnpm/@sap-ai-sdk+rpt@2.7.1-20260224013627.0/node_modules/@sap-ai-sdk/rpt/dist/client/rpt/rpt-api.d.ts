import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
import type { PredictRequestPayload, PredictResponsePayload } from './schema/index.js';
/**
 * Representation of the 'RptApi'.
 * This API is part of the 'rpt' service.
 * @internal
 */
export declare const RptApi: {
    _defaultBasePath: undefined;
    /**
     * Make in-context predictions for specified target columns.
     * Either "rows" or "columns" must be provided and must contain both context and query rows.
     * You can optionally send gzip-compressed JSON payloads and set a "Content-Encoding: gzip" header.
     * @param body - Request body.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    predict: (body: PredictRequestPayload) => OpenApiRequestBuilder<PredictResponsePayload>;
    /**
     * Make in-context predictions for specified target columns based on provided table data Parquet file.
     * @param body - Request body.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    predictParquet: (body: any) => OpenApiRequestBuilder<PredictResponsePayload>;
};
//# sourceMappingURL=rpt-api.d.ts.map