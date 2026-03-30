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
  version: '1.0.0-dev'
};
