/**
 * Environment Configuration
 * 
 * MCP endpoints pointing to existing services in src/data
 */

export const environment = {
  production: false,
  
  // MCP Endpoints (Backend services from src/data)
  langchainMcpUrl: 'http://localhost:9140/mcp',
  streamingMcpUrl: 'http://localhost:9190/mcp',
  
  // Optional: MCP Authentication Token
  mcpAuthToken: '',
  
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