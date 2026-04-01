import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, forkJoin, map, Observable, of } from 'rxjs';
import { LiveDemoConfig, validateLiveDemoConfig } from './live-demo-config';
import { environment } from '../../environments/environment';

export type LiveDemoRoute = 'generative' | 'joule' | 'components' | 'mcp';
type ServiceName = 'AG-UI' | 'OpenAI' | 'MCP';

export interface ServiceCheck {
  name: ServiceName;
  url: string;
  ok: boolean;
  status: number;
  error?: string;
}

export interface RouteReadiness {
  route: LiveDemoRoute;
  blocking: boolean;
  checks: ServiceCheck[];
}

const ROUTE_DEPENDENCIES: Record<LiveDemoRoute, ServiceName[]> = {
  generative: ['AG-UI'],
  joule: ['AG-UI'],
  components: ['OpenAI'],
  mcp: ['MCP'],
};

@Injectable({ providedIn: 'root' })
export class LiveDemoHealthService {
  private readonly config: LiveDemoConfig;

  constructor(private readonly http: HttpClient) {
    this.config = validateLiveDemoConfig(environment as LiveDemoConfig);
  }

  checkRouteReadiness(route: LiveDemoRoute): Observable<RouteReadiness> {
    const serviceNames = ROUTE_DEPENDENCIES[route];
    const checks$ = serviceNames.map((serviceName) => this.checkService(serviceName));

    return forkJoin(checks$).pipe(
      map((checks) => ({
        route,
        blocking: checks.some((check) => !check.ok),
        checks,
      })),
    );
  }

  checkAllServices(): Observable<ServiceCheck[]> {
    return forkJoin([
      this.checkService('AG-UI'),
      this.checkService('OpenAI'),
      this.checkService('MCP'),
    ]);
  }

  private checkService(name: ServiceName): Observable<ServiceCheck> {
    const url = this.getServiceUrl(name);
    return this.http.get(url, { observe: 'response' }).pipe(
      map((response) => ({
        name,
        url,
        ok: response.status >= 200 && response.status < 400,
        status: response.status,
      })),
      catchError((error: { status?: number; message?: string }) =>
        of({
          name,
          url,
          ok: false,
          status: error?.status ?? 0,
          error: error?.message ?? 'Request failed',
        }),
      ),
    );
  }

  private getServiceUrl(name: ServiceName): string {
    switch (name) {
      case 'AG-UI':
        return this.config.mcpBaseUrl.replace(/\/mcp$/, '/health');
      case 'OpenAI':
        return this.config.openAiBaseUrl.replace(/\/$/, '') + '/health';
      case 'MCP':
        return this.config.mcpBaseUrl.replace(/\/mcp$/, '/health');
    }
  }
}
