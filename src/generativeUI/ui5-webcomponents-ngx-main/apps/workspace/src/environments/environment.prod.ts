// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export const environment = {
  production: true,
  agUiEndpoint: '/ag-ui/run',
  agUiAuthToken: '',
  /** Suite gateway canonical paths (see gateway/README.md). Legacy /api/* aliases exist in nginx. */
  openAiBaseUrl: '/api/v1/ui5/openai',
  trainingApiUrl: '/api/v1/training',
  auditSinkToken: '',
  ocrInternalToken: '',
  /** Must end with `/mcp` so ExperienceHealthService can derive `/health`. */
  mcpBaseUrl: '/api/v1/ui5/mcp/mcp',
  requireRealBackends: true as const,
  collabWsUrl: '/collab',
  collabUserId: 'sap-ai-user-default',
  collabDisplayName: 'SAP AI User',
};
