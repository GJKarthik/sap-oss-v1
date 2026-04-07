export const environment = {
  production: true,
  apiBaseUrl: '/api',
  requireAuth: window.__TRAINING_CONFIG__?.requireAuth ?? false,
  enableDebugLogs: false,
  toastDuration: {
    success: 3000,
    error: 8000,
    warning: 6000,
    info: 3000,
  },
  features: {
    enableChat: true,
    enableGraphExplorer: true,
    enableModelOptimizer: true,
  },
  version: '1.0.0',
  collabWsUrl: '/collab',
  collabUserId: '',
  collabDisplayName: '',
  palMcpUrl: '/mcp/pal',
};
