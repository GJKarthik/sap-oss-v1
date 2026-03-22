export const environment = {
  production: true,
  apiBaseUrl: (window as any).__SAP_CONFIG__?.apiBaseUrl || '/api/v1',
  langchainMcpUrl: (window as any).__SAP_CONFIG__?.langchainMcpUrl || '/api/langchain/mcp',
  streamingMcpUrl: (window as any).__SAP_CONFIG__?.streamingMcpUrl || '/api/streaming/mcp',
  mcpAuthToken: '',
  hanaHost: '',
  hanaPort: 443,
  aiCoreBaseUrl: '',
  aiCoreResourceGroup: 'default',
  enableRag: true,
  enableStreaming: true,
  enableKuzuGraph: true,
};
