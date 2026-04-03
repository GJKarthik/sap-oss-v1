// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export const environment = {
  production: true,
  agUiEndpoint: '/ag-ui/run',
  openAiBaseUrl: 'http://localhost:8400',
  ocrInternalToken: '',
  mcpBaseUrl: 'http://localhost:9160/mcp',
  requireRealBackends: true as const,
  collabWsUrl: '/collab',
};
