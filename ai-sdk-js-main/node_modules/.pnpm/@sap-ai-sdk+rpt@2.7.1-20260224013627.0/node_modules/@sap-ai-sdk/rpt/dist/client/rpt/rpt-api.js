/*
 * Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved.
 *
 * This is a generated file powered by the SAP Cloud SDK for JavaScript.
 */
import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
/**
 * Representation of the 'RptApi'.
 * This API is part of the 'rpt' service.
 * @internal
 */
export const RptApi = {
    _defaultBasePath: undefined,
    /**
     * Make in-context predictions for specified target columns.
     * Either "rows" or "columns" must be provided and must contain both context and query rows.
     * You can optionally send gzip-compressed JSON payloads and set a "Content-Encoding: gzip" header.
     * @param body - Request body.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    predict: (body) => new OpenApiRequestBuilder('post', '/predict', {
        body
    }, RptApi._defaultBasePath),
    /**
     * Make in-context predictions for specified target columns based on provided table data Parquet file.
     * @param body - Request body.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    predictParquet: (body) => new OpenApiRequestBuilder('post', '/predict_parquet', {
        body
    }, RptApi._defaultBasePath)
};
//# sourceMappingURL=rpt-api.js.map