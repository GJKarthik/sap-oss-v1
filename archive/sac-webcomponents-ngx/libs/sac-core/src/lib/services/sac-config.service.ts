/**
 * SAC Config Service
 *
 * Manages SAC configuration and provides access to settings.
 */

import { Injectable, inject } from '@angular/core';
import { SAC_CONFIG } from '../tokens';
import { SacConfig, SacApiConfig, SacAuthConfig } from '../types/config.types';

const DEFAULT_API_VERSION = '2025.19';
const DEFAULT_TIMEOUT = 30000;

@Injectable({ providedIn: 'root' })
export class SacConfigService {
  private readonly injectedConfig = inject(SAC_CONFIG, { optional: true });
  private readonly config: SacConfig;

  constructor() {
    this.config = this.injectedConfig ?? {
      apiUrl: '',
      authToken: '',
      tenant: '',
    };
  }

  /** Get the full configuration */
  getConfig(): Readonly<SacConfig> {
    return Object.freeze({ ...this.config });
  }

  /** Get API URL */
  get apiUrl(): string {
    return this.config.apiUrl;
  }

  /** Get auth token */
  get authToken(): string {
    return this.config.authToken;
  }

  /** Get tenant ID */
  get tenant(): string {
    return this.config.tenant;
  }

  /** Get API version */
  get apiVersion(): string {
    return this.config.apiVersion ?? DEFAULT_API_VERSION;
  }

  /** Get timeout */
  get timeout(): number {
    return this.config.timeout ?? DEFAULT_TIMEOUT;
  }

  /** Check if debug mode is enabled */
  get isDebug(): boolean {
    return this.config.debug ?? false;
  }

  /** Get API configuration */
  getApiConfig(): SacApiConfig {
    return {
      baseUrl: this.apiUrl,
      headers: {
        'Authorization': `Bearer ${this.authToken}`,
        'Content-Type': 'application/json',
        'X-SAC-Tenant': this.tenant,
        'X-SAC-API-Version': this.apiVersion,
        ...(this.config.customHeaders ?? {}),
      },
      timeout: this.timeout,
    };
  }

  /** Build full API URL for an endpoint */
  buildUrl(endpoint: string): string {
    const base = this.apiUrl.endsWith('/') 
      ? this.apiUrl.slice(0, -1) 
      : this.apiUrl;
    const path = endpoint.startsWith('/') 
      ? endpoint 
      : `/${endpoint}`;
    return `${base}${path}`;
  }

  /** Check if configuration is valid */
  isConfigured(): boolean {
    return !!(this.config.apiUrl && this.config.authToken && this.config.tenant);
  }
}
