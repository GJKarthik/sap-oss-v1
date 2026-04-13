import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, forkJoin, map, Observable, of } from 'rxjs';
import { ExperienceRuntimeConfig, validateExperienceRuntimeConfig } from './experience-runtime-config';
import { environment } from '../../environments/environment';
import { WorkspaceService } from './workspace.service';

export type ExperienceRoute = 'generative' | 'joule' | 'components' | 'mcp' | 'ocr';
type ServiceName = 'AG-UI' | 'OpenAI' | 'MCP';

export interface ServiceCheck {
  name: ServiceName;
  url: string;
  ok: boolean;
  status: number;
  error?: string;
}

export interface TrainingCapabilitiesPayload {
  db_backend: string;
  database: string;
  hana_vector: string;
  vllm_turboquant: string;
  aicore_configured: boolean;
  aicore_reachable: string;
  pal_route: string;
}

export interface StackLayerCheck {
  id: string;
  labelKey: string;
  status: string;
  /** false = failing layer; true = healthy or intentionally optional (unconfigured). */
  ok: boolean;
}

export interface TrainingStackResult {
  layers: StackLayerCheck[];
  blocksWorkspace: boolean;
  httpError?: string;
}

export interface RouteReadiness {
  route: ExperienceRoute;
  blocking: boolean;
  checks: ServiceCheck[];
}

const ROUTE_DEPENDENCIES: Record<ExperienceRoute, ServiceName[]> = {
  generative: ['AG-UI'],
  joule: ['AG-UI'],
  components: ['OpenAI'],
  mcp: ['MCP'],
  ocr: ['OpenAI'],
};

@Injectable({ providedIn: 'root' })
export class ExperienceHealthService {
  private readonly config: ExperienceRuntimeConfig;

  constructor(
    private readonly http: HttpClient,
    private readonly workspaceService: WorkspaceService,
  ) {
    this.config = validateExperienceRuntimeConfig(environment as ExperienceRuntimeConfig);
  }

  checkRouteReadiness(route: ExperienceRoute): Observable<RouteReadiness> {
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

  /**
   * Training API aggregated capabilities (HANA vector, vLLM, AI Core, PAL upstream).
   * Uses environment.trainingApiUrl (gateway /api/v1/training or local absolute URL).
   */
  fetchTrainingStack(): Observable<TrainingStackResult> {
    const base = environment.trainingApiUrl.replace(/\/$/, '');
    const url = `${base}/capabilities`;
    return this.http.get<TrainingCapabilitiesPayload>(url).pipe(
      map((p) => {
        const layers: StackLayerCheck[] = [
          {
            id: 'database',
            labelKey: 'READINESS_LAYER_DATABASE',
            status: p.database,
            ok: p.database === 'healthy',
          },
          {
            id: 'hana_vector',
            labelKey: 'READINESS_LAYER_HANA_VECTOR',
            status: p.hana_vector,
            ok: p.hana_vector === 'healthy' || p.hana_vector === 'unconfigured',
          },
          {
            id: 'vllm_turboquant',
            labelKey: 'READINESS_LAYER_VLLM',
            status: p.vllm_turboquant,
            ok: p.vllm_turboquant === 'healthy',
          },
          {
            id: 'aicore',
            labelKey: 'READINESS_LAYER_AICORE',
            status: p.aicore_configured ? p.aicore_reachable : 'unconfigured',
            ok: !p.aicore_configured || p.aicore_reachable === 'healthy',
          },
          {
            id: 'pal_route',
            labelKey: 'READINESS_LAYER_PAL',
            status: p.pal_route,
            ok: p.pal_route === 'healthy' || p.pal_route === 'unconfigured',
          },
        ];
        const blocksWorkspace =
          p.database !== 'healthy' ||
          (p.aicore_configured && p.aicore_reachable === 'unhealthy');
        return { layers, blocksWorkspace };
      }),
      catchError((err: { message?: string }) =>
        of({
          layers: [] as StackLayerCheck[],
          blocksWorkspace: true,
          httpError: err?.message ?? 'Request failed',
        }),
      ),
    );
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
    const openAiBase = this.workspaceService.effectiveOpenAiBaseUrl();
    const mcpBase = this.workspaceService.effectiveMcpBaseUrl();
    switch (name) {
      case 'AG-UI':
        return mcpBase.replace(/\/mcp$/, '/health');
      case 'OpenAI':
        return openAiBase.replace(/\/$/, '') + '/health';
      case 'MCP':
        return mcpBase.replace(/\/mcp$/, '/health');
    }
  }
}
