export const environment = {
  production: true,
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
