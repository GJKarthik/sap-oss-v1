type RuntimeConfig = {
  apiBaseUrl?: string;
  langchainMcpUrl?: string;
  streamingMcpUrl?: string;
};

const runtimeConfig = (window as Window & { __SAP_CONFIG__?: RuntimeConfig }).__SAP_CONFIG__;
const apiBaseUrl = runtimeConfig?.apiBaseUrl || '/api/v1';

export const environment = {
  production: true,
  apiBaseUrl,
  langchainMcpUrl: runtimeConfig?.langchainMcpUrl || `${apiBaseUrl}/mcp/langchain`,
  streamingMcpUrl: runtimeConfig?.streamingMcpUrl || `${apiBaseUrl}/mcp/streaming`,
  hanaHost: '',
  hanaPort: 443,
  aiCoreBaseUrl: '',
  aiCoreResourceGroup: 'default',
  enableRag: true,
  enableStreaming: true,
  enableKuzuGraph: true,
};
