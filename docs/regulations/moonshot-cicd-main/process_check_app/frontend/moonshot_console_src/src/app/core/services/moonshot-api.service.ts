import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable, catchError, map, of, tap, throwError } from 'rxjs';

import {
  MoonshotApiConfig,
  MoonshotConfigSummaryResponse,
  MoonshotHealthResponse,
  MoonshotRunDetailResponse,
  MoonshotRunListResponse,
  MoonshotRunOutput,
  MoonshotRunRequest,
  MoonshotRunResponse,
  MoonshotStoredRun,
  MoonshotTestConfigsResponse,
} from '../models/moonshot.model';

const STORAGE_KEY = 'moonshot_console_config';

const DEFAULT_CONFIG: MoonshotApiConfig = {
  baseUrl: 'http://localhost:8088',
  useMockFallback: true,
  timeoutMs: 30000,
};

@Injectable({ providedIn: 'root' })
export class MoonshotApiService {
  private readonly http = inject(HttpClient);

  private readonly configSubject = new BehaviorSubject<MoonshotApiConfig>(this.loadConfig());
  readonly config$ = this.configSubject.asObservable();

  private readonly fallbackSubject = new BehaviorSubject<boolean>(false);
  readonly fallbackMode$ = this.fallbackSubject.asObservable();

  private readonly lastErrorSubject = new BehaviorSubject<string | null>(null);
  readonly lastError$ = this.lastErrorSubject.asObservable();

  private readonly mockRuns: MoonshotStoredRun[] = [
    {
      run_id: 'sample-offline-run',
      test_config_id: 'sample_test',
      connector: 'my-gpt-4o',
      status: 'completed',
      result_path: 'data/results/sample-offline-run.json',
      start_time_unix: Math.floor(Date.now() / 1000) - 180,
      end_time_unix: Math.floor(Date.now() / 1000) - 120,
      duration_seconds: 60,
      dry_run_prompts: 5,
    },
  ];

  getConfig(): MoonshotApiConfig {
    return { ...this.configSubject.value };
  }

  setConfig(partial: Partial<MoonshotApiConfig>): void {
    const next: MoonshotApiConfig = {
      ...this.configSubject.value,
      ...partial,
    };
    this.configSubject.next(next);
    this.saveConfig(next);
  }

  checkHealth(): Observable<MoonshotHealthResponse> {
    const url = `${this.baseUrl()}/api/moonshot/health`;
    const request$ = this.http.get<MoonshotHealthResponse>(url);

    return this.withFallback(request$, () => ({
      status: 'ok',
      service: 'moonshot-gateway',
      moonshot_root: 'regulations/moonshot-cicd-main',
      moonshot_binary: 'regulations/moonshot-cicd-main/zig/zig-out/bin/moonshot-cicd-zig',
      binary_exists: true,
      odata_base_url: 'http://127.0.0.1:9882',
      odata_reachable: false,
    }), 'Moonshot health check');
  }

  getConfigSummary(): Observable<MoonshotConfigSummaryResponse> {
    const url = `${this.baseUrl()}/api/moonshot/config/summary`;
    const request$ = this.http.get<MoonshotConfigSummaryResponse>(url);

    return this.withFallback(request$, () => ({
      status: 'ok',
      common: {
        max_concurrency: 5,
        max_calls_per_minute: 60,
        max_attempts: 3,
      },
      connectors: ['my-gpt-4o', 'my-gpt-4.1-mini'],
      metrics: ['exact_match', 'refusal_adapter'],
      attack_modules: ['prompt_injection'],
      connector_count: 2,
      metric_count: 2,
      attack_module_count: 1,
    }), 'Moonshot config summary');
  }

  getTestConfigs(): Observable<MoonshotTestConfigsResponse> {
    const url = `${this.baseUrl()}/api/moonshot/test-configs`;
    const request$ = this.http.get<MoonshotTestConfigsResponse>(url);

    return this.withFallback(request$, () => ({
      status: 'ok',
      test_config_ids: ['sample_test'],
      test_configs: {
        sample_test: [
          {
            name: 'Sample Benchmark',
            type: 'benchmark',
            dataset: 'sample_dataset',
            metric: 'exact_match',
          },
        ],
      },
    }), 'Moonshot test config list');
  }

  triggerRun(payload: MoonshotRunRequest): Observable<MoonshotRunResponse> {
    const url = `${this.baseUrl()}/api/moonshot/runs`;
    const request$ = this.http.post<MoonshotRunResponse>(url, payload).pipe(
      map((response) => {
        if (response.status === 'error') {
          const reason = response.error ?? response.stderr ?? 'Unknown execution error';
          throw new Error(reason);
        }
        return response;
      })
    );

    return this.withFallback(request$, () => {
      const started = Math.floor(Date.now() / 1000);
      const output: MoonshotRunOutput = {
        status: 'success',
        run_id: payload.run_id,
        test_config_id: payload.test_config_id,
        connector: payload.connector,
        result_path: `data/results/${payload.run_id}.json`,
        tests_executed: 1,
        dry_run_prompts: payload.dry_run ? 5 : 0,
        duration_seconds: 1,
      };

      this.mockRuns.unshift({
        run_id: output.run_id,
        test_config_id: output.test_config_id,
        connector: output.connector,
        status: 'completed',
        result_path: output.result_path,
        start_time_unix: started,
        end_time_unix: started + 1,
        duration_seconds: 1,
        dry_run_prompts: output.dry_run_prompts,
      });

      return {
        status: 'success',
        run: output,
        persisted_to_odata: false,
      };
    }, 'Moonshot run execution');
  }

  listRuns(): Observable<MoonshotRunListResponse> {
    const url = `${this.baseUrl()}/api/moonshot/runs`;
    const request$ = this.http.get<MoonshotRunListResponse>(url);

    return this.withFallback(request$, () => ({
      runs: [...this.mockRuns],
    }), 'Moonshot run history');
  }

  getRun(runId: string): Observable<MoonshotRunDetailResponse> {
    const url = `${this.baseUrl()}/api/moonshot/runs/${encodeURIComponent(runId)}`;
    const request$ = this.http.get<MoonshotRunDetailResponse>(url);

    return this.withFallback(request$, () => ({
      run: this.mockRuns.find((run) => run.run_id === runId) ?? null,
    }), 'Moonshot run detail');
  }

  private withFallback<T>(request$: Observable<T>, mockFactory: () => T, context: string): Observable<T> {
    return request$.pipe(
      tap(() => {
        this.fallbackSubject.next(false);
        this.lastErrorSubject.next(null);
      }),
      catchError((error) => {
        const message = this.describeHttpError(context, error);
        this.lastErrorSubject.next(message);

        if (this.configSubject.value.useMockFallback) {
          this.fallbackSubject.next(true);
          return of(mockFactory());
        }

        this.fallbackSubject.next(false);
        return throwError(() => new Error(message));
      })
    );
  }

  private baseUrl(): string {
    return this.configSubject.value.baseUrl.replace(/\/$/, '');
  }

  private describeHttpError(context: string, error: unknown): string {
    const errorObject = error as { status?: number; message?: string; error?: { message?: string } };
    const reason = errorObject.error?.message ?? errorObject.message ?? 'Request failed';
    const status = errorObject.status ? `HTTP ${errorObject.status}` : 'network error';
    return `${context}: ${status} - ${reason}`;
  }

  private loadConfig(): MoonshotApiConfig {
    if (typeof window === 'undefined') {
      return { ...DEFAULT_CONFIG };
    }

    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return { ...DEFAULT_CONFIG };
    }

    try {
      const parsed = JSON.parse(raw) as Partial<MoonshotApiConfig>;
      return {
        ...DEFAULT_CONFIG,
        ...parsed,
      };
    } catch {
      return { ...DEFAULT_CONFIG };
    }
  }

  private saveConfig(config: MoonshotApiConfig): void {
    if (typeof window === 'undefined') {
      return;
    }
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  }
}
