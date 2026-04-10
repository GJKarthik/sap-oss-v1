export const environment = {
  production: true,
  apiBaseUrl: window.__TRAINING_CONFIG__?.apiBaseUrl ?? '/api',
  requireAuth: window.__TRAINING_CONFIG__?.requireAuth ?? false,
  authMode: window.__TRAINING_CONFIG__?.authMode ?? (window.__TRAINING_CONFIG__?.requireAuth ? 'token' : 'none'),
  enableDebugLogs: false,
  toastDuration: {
    success: 3000,
    error: 8000,
    warning: 6000,
    info: 3000,
  },
  features: {
    enableChat: true,
    enableLineageExplorer: true,
    enableModelOptimizer: true,
  },
  version: '1.0.0',
  collabWsUrl: '/collab',
  collabUserId: '',
  collabDisplayName: '',
  palMcpUrl: '/mcp/pal',
};
