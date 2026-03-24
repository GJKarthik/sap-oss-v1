const apiBaseUrl = '/api/v1';

export const environment = {
  production: false,

  // API base URL (FastAPI backend)
  apiBaseUrl,

  // MCP proxy endpoints
  langchainMcpUrl: `${apiBaseUrl}/mcp/langchain`,
  streamingMcpUrl: `${apiBaseUrl}/mcp/streaming`,

  // HANA Cloud Connection
  hanaHost: '',
  hanaPort: 443,

  // AI Core Configuration
  aiCoreBaseUrl: '',
  aiCoreResourceGroup: 'default',

  // Feature Flags
  enableRag: true,
  enableStreaming: true,
  enableKuzuGraph: true,
};
