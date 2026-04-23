// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
// This file can be replaced during build by using the `fileReplacements` array.
// `ng build` replaces `environment.ts` with `environment.prod.ts`.
// The list of file replacements can be found in `angular.json`.

export const environment = {
  production: false,
  agUiEndpoint: '/ag-ui/run',
  /** Optional: sent as SSE query param and Bearer on POST; leave empty for local dev. */
  agUiAuthToken: '',
  openAiBaseUrl: '/api/v1/ui5/openai',
  trainingApiUrl: '/api/v1/training',
  /** Optional: must match training api-server AUDIT_SINK_TOKEN when that env is set. */
  auditSinkToken: '',
  ocrInternalToken: '',
  mcpBaseUrl: '/api/v1/ui5/mcp/mcp',
  requireRealBackends: true as const,
  collabWsUrl: '/collab',
  collabUserId: 'sap-ai-user-default',
  collabDisplayName: 'SAP AI User',
};

/*
 * For easier debugging in development mode, you can import the following file
 * to ignore zone related error stack frames such as `zone.run`, `zoneDelegate.invokeTask`.
 *
 * This import should be commented out in production mode because it will have a negative impact
 * on performance if an error is thrown.
 */
// import 'zone.js/plugins/zone-error';  // Included with Angular CLI.
