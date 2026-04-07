import { Injectable, inject } from '@angular/core';
import { SACRestAPIClient } from '@sap-oss/sac-sdk';
import { SacAuthService } from './sac-auth.service';
import { SacConfigService } from './sac-config.service';

@Injectable()
export class SacApiService {
  private readonly authService = inject(SacAuthService);
  private readonly configService = inject(SacConfigService);
  private readonly client: SACRestAPIClient;

  constructor() {
    const config = this.configService.getConfig();

    this.client = new SACRestAPIClient({
      serverUrl: this.configService.apiUrl,
      apiVersion: this.configService.apiVersion,
      timeout: this.configService.timeout,
      headers: config.customHeaders ?? {},
      getAuthToken: () => this.authService.getToken(),
    });
  }

  updateToken(token: string): void {
    this.authService.setToken(token);
  }

  clearToken(): void {
    this.authService.clearToken();
  }

  async get<T>(path: string): Promise<T> {
    return this.client.get<T>(path);
  }

  async post<T>(path: string, body?: unknown): Promise<T> {
    return this.client.post<T>(path, body);
  }

  async put<T>(path: string, body?: unknown): Promise<T> {
    return this.client.put<T>(path, body);
  }

  async delete<T>(path: string): Promise<T> {
    return this.client.del<T>(path);
  }
}
