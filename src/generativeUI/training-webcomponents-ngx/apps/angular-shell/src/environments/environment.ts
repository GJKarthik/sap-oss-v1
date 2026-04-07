export const environment = {
  production: false,
  apiBaseUrl: '/api',
  requireAuth: false,
  enableDebugLogs: true,
  toastDuration: {
    success: 5000,
    error: 8000,
    warning: 6000,
    info: 5000,
  },
  features: {
    enableChat: true,
    enableGraphExplorer: true,
    enableModelOptimizer: true,
  },
  version: '1.0.0-dev',
  collabWsUrl: `${typeof window !== 'undefined' ? window.location.protocol.replace('http', 'ws') : 'ws:'}//localhost:8200/collab`,
  collabUserId: 'training-user-default',
  collabDisplayName: 'Training User',
  elasticsearchMcpUrl: 'http://localhost:3001',
  palMcpUrl: 'http://localhost:3002',
};
