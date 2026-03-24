import { getRuntimeConfig } from './runtime-config';

const runtimeConfig = getRuntimeConfig();
const apiBaseUrl = runtimeConfig.apiBaseUrl || '/api/v1';

export const environment = {
  production: false,
  apiBaseUrl,
  langchainMcpUrl: runtimeConfig.langchainMcpUrl || `${apiBaseUrl}/mcp/langchain`,
  streamingMcpUrl: runtimeConfig.streamingMcpUrl || `${apiBaseUrl}/mcp/streaming`,
  hanaHost: '',
  hanaPort: 443,
  aiCoreBaseUrl: '',
  aiCoreResourceGroup: 'default',
  enableRag: true,
  enableStreaming: true,
  enableKuzuGraph: true,
};
