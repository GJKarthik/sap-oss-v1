import { getRuntimeConfig } from './runtime-config';

const runtimeConfig = getRuntimeConfig();
const apiBaseUrl = runtimeConfig.apiBaseUrl || '/api/v1';
const elasticsearchMcpUrl = runtimeConfig.elasticsearchMcpUrl || runtimeConfig.langchainMcpUrl || `${apiBaseUrl}/mcp/elasticsearch`;
const palMcpUrl = runtimeConfig.palMcpUrl || runtimeConfig.streamingMcpUrl || `${apiBaseUrl}/mcp/pal`;

export const environment = {
  production: false,
  apiBaseUrl,
  elasticsearchMcpUrl,
  palMcpUrl,
  hanaHost: '',
  hanaPort: 443,
  aiCoreBaseUrl: '',
  aiCoreResourceGroup: 'default',
  enableRag: true,
  enablePalWorkbench: true,
  enableKuzuGraph: true,
  collabWsUrl: `${typeof window !== 'undefined' ? window.location.protocol.replace('http', 'ws') : 'ws:'}//localhost:8200/collab`,
  collabUserId: 'aifabric-user-default',
  collabDisplayName: 'AI Fabric User',
};
