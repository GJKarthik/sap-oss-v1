/**
 * Production environment configuration
 */
export const environment = {
  production: true,
  apiBaseUrl: '/api',
  requireAuth: true,
  enableDebugLogs: false,
  toastDuration: {
    success: 4000,
    error: 10000,
    warning: 6000,
    info: 4000,
  },
  features: {
    enableChat: true,
    enableGraphExplorer: true,
    enableModelOptimizer: true,
  },
};