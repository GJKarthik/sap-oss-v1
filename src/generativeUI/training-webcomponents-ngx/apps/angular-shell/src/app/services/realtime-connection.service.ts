import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { catchError, map } from 'rxjs/operators';
import { WorkspaceService } from './workspace.service';

@Injectable({ providedIn: 'root' })
export class RealtimeConnectionService {
  private readonly http = inject(HttpClient);
  private readonly workspace = inject(WorkspaceService);

  buildApiUrl(path = '/'): string {
    const apiBase = this.resolveApiBase();
    const normalizedPath = this.normalizePath(path);
    return new URL(this.stripLeadingSlash(normalizedPath), this.ensureTrailingSlash(apiBase)).toString();
  }

  buildWebSocketUrl(path: string): string {
    const apiBase = this.resolveApiBase();
    const wsTarget = new URL(this.buildServicePath(path), `${apiBase.protocol}//${apiBase.host}`);
    wsTarget.protocol = apiBase.protocol === 'https:' ? 'wss:' : 'ws:';
    return wsTarget.toString();
  }

  probeApiHealth(): Observable<boolean> {
    return this.http.get(this.buildApiUrl('/health'), { observe: 'response' }).pipe(
      map((response) => response.status >= 200 && response.status < 500),
      catchError(() => of(false)),
    );
  }

  private resolveApiBase(): URL {
    const apiBaseUrl = this.workspace.effectiveApiBaseUrl();
    const origin = typeof window !== 'undefined' ? window.location.origin : 'http://localhost';
    return new URL(apiBaseUrl || '/api', origin);
  }

  private buildServicePath(path: string): string {
    const apiBase = this.resolveApiBase();
    const rootPath = apiBase.pathname.replace(/\/api\/?$/, '');
    return this.joinPaths(rootPath || '/', this.normalizePath(path));
  }

  private ensureTrailingSlash(url: URL): string {
    return url.toString().endsWith('/') ? url.toString() : `${url.toString()}/`;
  }

  private normalizePath(path: string): string {
    if (!path || path === '/') {
      return '/';
    }
    return path.startsWith('/') ? path : `/${path}`;
  }

  private stripLeadingSlash(path: string): string {
    return path.replace(/^\/+/, '');
  }

  private joinPaths(basePath: string, path: string): string {
    return `${basePath.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`.replace(/\/{2,}/g, '/');
  }
}
