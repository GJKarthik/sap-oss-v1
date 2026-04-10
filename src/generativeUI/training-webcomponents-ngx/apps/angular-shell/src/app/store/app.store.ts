import { computed, inject } from '@angular/core';
import {
  signalStore,
  withState,
  withMethods,
  withComputed,
  patchState,
  withHooks,
} from '@ngrx/signals';
import { rxMethod } from '@ngrx/signals/rxjs-interop';
import { pipe, switchMap, tap, catchError, of, interval, forkJoin, Subject, takeUntil } from 'rxjs';
import { ApiService } from '../services/api.service';
import { AppMode } from '../shared/utils/mode.types';
import {
  getModeConfig,
  getPillsForMode,
  loadPersistedMode,
  persistMode,
} from '../shared/utils/mode.helpers';

export interface HealthStatus {
  status: string;
  dependencies: {
    database: string;
    hana_vector: string;
    vllm_turboquant: string;
  };
}

export interface GpuTelemetry {
  gpu_name: string;
  memory_total: number;
  memory_used: number;
  utilization: number;
  cuda_version: string;
}

interface AppState {
  health: { data: HealthStatus | null; loading: boolean };
  gpu: { data: GpuTelemetry | null; loading: boolean };
  pipelineState: 'idle' | 'running' | 'completed' | 'error';
  trainingPairCount: number;
  activeMode: AppMode;
}

function inferPipelineState(
  health: HealthStatus | null,
  current: AppState['pipelineState']
): AppState['pipelineState'] {
  if (!health) return current;
  const deps = health.dependencies;
  const allHealthy = deps.database === 'healthy' && deps.hana_vector === 'healthy' && deps.vllm_turboquant === 'healthy';
  if (health.status === 'healthy' && allHealthy) return 'idle';
  if (health.status !== 'healthy') return 'error';
  return current;
}

export const AppStore = signalStore(
  { providedIn: 'root' },
  withState<AppState>({
    health: { data: null, loading: false },
    gpu: { data: null, loading: false },
    pipelineState: 'idle',
    trainingPairCount: 13952,
    activeMode: loadPersistedMode(),
  }),
  withComputed((store) => ({
    isHealthy: computed(() => store.health.data()?.status === 'healthy'),
    gpuUtilization: computed(() => store.gpu.data()?.utilization ?? 0),
    gpuMemoryUsed: computed(() => store.gpu.data()?.memory_used ?? 0),
    gpuMemoryTotal: computed(() => store.gpu.data()?.memory_total ?? 0),
    
    // ── Steve's Platform Narrative ──────────────────────────────────────────
    platformNarrative: computed(() => {
      const h = store.health.data();
      const p = store.pipelineState();
      
      if (p === 'running') return 'narrative.running';
      if (!h) return 'narrative.initializing';
      if (h.status === 'healthy') return 'narrative.healthy';
      if (h.dependencies.hana_vector !== 'healthy') return 'narrative.hanaOffline';
      return 'narrative.degraded';
    }),

    // ── Jony's Atmospheric Color ──────────────────────────────────────────
    atmosphericClass: computed(() => {
      const p = store.pipelineState();
      const h = store.health.data();
      if (p === 'running') return 'aura--weaving';
      if (h?.status !== 'healthy' && h !== null) return 'aura--warning';
      return 'aura--idle';
    }),

    // ── Dashboard helpers ────────────────────────────────────────────────
    isDashboardLoading: computed(() => store.health.loading() || store.gpu.loading()),
    healthBadge: computed(() => store.health.data()?.status === 'healthy' ? 'Positive' : 'Negative'),

    // ── Mode computeds ────────────────────────────────────────────────
    modeConfig: computed(() => getModeConfig(store.activeMode())),
    modePills: computed(() => getPillsForMode(store.activeMode())),
    modeSystemPrompt: computed(() => getModeConfig(store.activeMode()).systemPromptPrefix),
    modeConfirmationLevel: computed(() => getModeConfig(store.activeMode()).confirmationLevel),
  })),
  withMethods((store, api = inject(ApiService)) => ({
    loadDashboardData: rxMethod<void>(
      pipe(
        tap(() => {
          patchState(store, (s) => ({ health: { ...s.health, loading: true }, gpu: { ...s.gpu, loading: true } }));
        }),
        switchMap(() => 
          forkJoin({
            health: api.get<HealthStatus>('/health').pipe(catchError(() => of(null))),
            gpu: api.get<GpuTelemetry>('/gpu/status').pipe(catchError(() => of(null))),
          })
        ),
        tap((res) => {
          patchState(store, {
            health: { data: res.health, loading: false },
            gpu: { data: res.gpu, loading: false },
            pipelineState: inferPipelineState(res.health, store.pipelineState()),
          });
        })
      )
    ),
    setPipelineState: (state: 'idle' | 'running' | 'completed' | 'error') => patchState(store, { pipelineState: state }),
    setMode: (mode: AppMode) => {
      patchState(store, { activeMode: mode });
      persistMode(mode);
    },
    forceRefresh: () => {
      patchState(store, (s) => ({ health: { ...s.health, loading: true }, gpu: { ...s.gpu, loading: true } }));
      forkJoin({
        health: api.get<HealthStatus>('/health').pipe(catchError(() => of(null))),
        gpu: api.get<GpuTelemetry>('/gpu/status').pipe(catchError(() => of(null))),
      }).subscribe((res) => {
        patchState(store, {
          health: { data: res.health, loading: false },
          gpu: { data: res.gpu, loading: false },
          pipelineState: inferPipelineState(res.health, store.pipelineState()),
        });
      });
    }
  })),
  withHooks((store) => {
    const destroy$ = new Subject<void>();
    return {
      onInit() {
        store.loadDashboardData();
        interval(10000).pipe(
          takeUntil(destroy$),
          tap(() => store.loadDashboardData())
        ).subscribe();
      },
      onDestroy() {
        destroy$.next();
        destroy$.complete();
      }
    };
  })
);
