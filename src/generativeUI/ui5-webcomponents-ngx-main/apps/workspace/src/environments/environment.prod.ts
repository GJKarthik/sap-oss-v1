// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export const environment = {
  production: true,
  agUiEndpoint: '/ag-ui/run',
  openAiBaseUrl: '/api/openai',
  trainingApiUrl: '/api/training',
  ocrInternalToken: '',
  mcpBaseUrl: '/api/mcp',
  requireRealBackends: true as const,
  collabWsUrl: '/collab',
  collabUserId: 'sap-ai-user-default',
  collabDisplayName: 'SAP AI User',
};
