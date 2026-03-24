/**
 * Environment Configuration
 *
 * Frontend environment configuration
 */

export const environment = {
  production: false,

  // API base URL (FastAPI backend)
  apiBaseUrl: 'http://localhost:8000/api/v1',

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