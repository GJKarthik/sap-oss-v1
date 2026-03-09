/**
 * SAC Configuration Types
 *
 * Configuration interfaces for SAP Analytics Cloud integration.
 * Derived from mangle/sac_widget.mg API endpoint specifications.
 */

/**
 * Main SAC configuration interface
 */
export interface SacConfig {
  /** SAC tenant API URL (e.g., https://tenant.sapanalytics.cloud) */
  apiUrl: string;

  /** OAuth/Bearer auth token */
  authToken: string;

  /** SAC tenant ID */
  tenant: string;

  /** Optional tenant name for display */
  tenantName?: string;

  /** API version to use (default: 2025.19) */
  apiVersion?: string;

  /** Request timeout in milliseconds */
  timeout?: number;

  /** Enable debug mode */
  debug?: boolean;

  /** Custom headers to include in requests */
  customHeaders?: Record<string, string>;
}

/**
 * API-specific configuration
 */
export interface SacApiConfig {
  /** Base URL for API requests */
  baseUrl: string;

  /** Default headers for all requests */
  headers: Record<string, string>;

  /** Request timeout in milliseconds */
  timeout: number;

  /** Retry configuration */
  retry?: {
    maxRetries: number;
    retryDelay: number;
    retryOn: number[];
  };

  /** Enable request/response logging */
  enableLogging?: boolean;
}

/**
 * Authentication configuration
 */
export interface SacAuthConfig {
  /** OAuth client ID */
  clientId?: string;

  /** OAuth client secret (for server-side only) */
  clientSecret?: string;

  /** OAuth token endpoint */
  tokenEndpoint?: string;

  /** OAuth authorization endpoint */
  authorizationEndpoint?: string;

  /** OAuth scopes to request */
  scopes?: string[];

  /** Refresh token */
  refreshToken?: string;

  /** Token expiry timestamp */
  tokenExpiry?: number;

  /** Auto-refresh token before expiry */
  autoRefresh?: boolean;
}

/**
 * Feature flags configuration
 */
export interface SacFeatureFlags {
  /** Enable planning features */
  enablePlanning?: boolean;

  /** Enable calendar integration */
  enableCalendar?: boolean;

  /** Enable data actions */
  enableDataActions?: boolean;

  /** Enable smart features (discovery, forecast) */
  enableSmartFeatures?: boolean;

  /** Enable export features */
  enableExport?: boolean;

  /** Enable commenting */
  enableComments?: boolean;
}