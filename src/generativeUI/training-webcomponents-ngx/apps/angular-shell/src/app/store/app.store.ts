import { computed, inject, effect } from '@angular/core';
import {
  signalStore,
  withState,
  withMethods,
  withComputed,
  patchState,
  withHooks,
} from '@ngrx/signals';
import { rxMethod } from '@ngrx/signals/rxjs-interop';
import { pipe, tap, catchError, of, timer, exhaustMap, retry } from 'rxjs';
import { webSocket } from 'rxjs/webSocket';
import { ApiService } from '../services/api.service';
import { ToastService } from '../services/toast.service';
import { NotificationService } from '../services/notification.service';

// ============================================================================
// Types
// ============================================================================

export interface GpuStatus {
  gpu_name: string;
  total_memory_gb: number;
  used_memory_gb: number;
  free_memory_gb: number;
  utilization_percent: number;
  temperature_c: number;
  driver_version: string;
  cuda_version: string;
}

export interface HealthStatus {
  status: string;
  service: string;
  version: string;
}

export interface GraphStats {
  available: boolean;
  pair_count: number;
}

export interface ModelInfo {
  name: string;
  size_gb: number;
  parameters: string;
  recommended_quant: string;
  t4_compatible: boolean;
}

export interface JobHistory {
  epoch: number;
  train_loss: number;
  val_loss: number;
}

export interface JobResponse {
  id: string;
  name: string;
  status: string;
  config: {
    model_name: string;
    quant_format: string;
    export_format: string;
  };
  created_at: string;
  progress: number;
  error?: string;
  history?: JobHistory[];
}

export type LoadingState = 'idle' | 'loading' | 'loaded' | 'error';

export interface CachedData<T> {
  data: T | null;
  lastFetched: number | null;
  state: LoadingState;
  error: string | null;
}

// ============================================================================
// App State
// ============================================================================

export type WsState = 'offline' | 'connecting' | 'connected' | 'reconnecting' | 'error';

interface AppState {
  // WebSockets
  wsState: WsState;

  // Health & GPU
  health: CachedData<HealthStatus>;
  gpu: CachedData<GpuStatus>;
  graphStats: CachedData<GraphStats>;
  
  // Model Optimizer
  models: CachedData<ModelInfo[]>;
  jobs: CachedData<JobResponse[]>;
  
  // Global UI
  sidebarCollapsed: boolean;
}

const initialCachedData = <T>(): CachedData<T> => ({
  data: null,
  lastFetched: null,
  state: 'idle',
  error: null,
});

const initialState: AppState = {
  wsState: 'offline',
  health: initialCachedData(),
  gpu: initialCachedData(),
  graphStats: initialCachedData(),
  models: initialCachedData(),
  jobs: initialCachedData(),
  sidebarCollapsed: false,
};

// ============================================================================
// Cache Configuration (Stale-While-Revalidate)
// ============================================================================

const CACHE_CONFIG = {
  health: { staleTime: 30_000, maxAge: 60_000 },      // 30s stale, 60s max
  gpu: { staleTime: 10_000, maxAge: 30_000 },         // 10s stale, 30s max
  graphStats: { staleTime: 60_000, maxAge: 120_000 }, // 60s stale, 2min max
  models: { staleTime: 300_000, maxAge: 600_000 },    // 5min stale, 10min max
  jobs: { staleTime: 5_000, maxAge: 15_000 },         // 5s stale, 15s max
} as const;
type CacheKey = keyof typeof CACHE_CONFIG;

function isCacheValid<T>(cached: CachedData<T>, key: keyof typeof CACHE_CONFIG): boolean {
  if (!cached.lastFetched) return false;
  const age = Date.now() - cached.lastFetched;
  return age < CACHE_CONFIG[key].maxAge;
}

function isCacheStale<T>(cached: CachedData<T>, key: keyof typeof CACHE_CONFIG): boolean {
  if (!cached.lastFetched) return true;
  const age = Date.now() - cached.lastFetched;
  return age >= CACHE_CONFIG[key].staleTime;
}

// ============================================================================
// Signal Store
// ============================================================================

export const AppStore = signalStore(
  { providedIn: 'root' },
  withState(initialState),
  
  withComputed((store) => ({
    // Derived health status
    isHealthy: computed(() => store.health().data?.status === 'healthy'),
    healthBadge: computed(() => 
      store.health().data?.status === 'healthy' ? 'status-success' : 'status-error'
    ),
    
    // GPU computed values
    gpuMemoryUsed: computed(() => {
      const gpu = store.gpu().data;
      return gpu ? gpu.used_memory_gb.toFixed(1) : '—';
    }),
    gpuMemoryTotal: computed(() => {
      const gpu = store.gpu().data;
      return gpu ? gpu.total_memory_gb.toFixed(1) : '—';
    }),
    gpuUtilization: computed(() => store.gpu().data?.utilization_percent ?? 0),
    
    // Graph stats
    trainingPairCount: computed(() => store.graphStats().data?.pair_count ?? 0),
    isGraphAvailable: computed(() => store.graphStats().data?.available ?? false),
    
    // Jobs
    pendingJobs: computed(() => 
      store.jobs().data?.filter((j) => j.status === 'pending' || j.status === 'running') ?? []
    ),
    completedJobs: computed(() =>
      store.jobs().data?.filter((j) => j.status === 'completed') ?? []
    ),
    
    // Loading states
    isDashboardLoading: computed(() => 
      store.health().state === 'loading' || 
      store.gpu().state === 'loading' ||
      store.graphStats().state === 'loading'
    ),
  })),
  
  withMethods((store, api = inject(ApiService), toast = inject(ToastService)) => {
    
    // Helper to update cached data
    const updateCache = <K extends CacheKey>(
      key: K,
      update: Partial<AppState[K]>
    ) => {
      const current = store[key]();
      patchState(store, { [key]: { ...current, ...update } } as Partial<AppState>);
    };
    
    return {
      // ======================================================================
      // Health
      // ======================================================================
      loadHealth: rxMethod<void>(
        pipe(
          tap(() => {
            const cached = store.health();
            if (!isCacheStale(cached, 'health') && cached.data) {
              return; // Use cached data
            }
            if (cached.state !== 'loading') {
              updateCache('health', { state: 'loading' });
            }
          }),
          exhaustMap(() => {
            const cached = store.health();
            if (isCacheValid(cached, 'health') && !isCacheStale(cached, 'health')) {
              return of(null); // Skip fetch, use cache
            }
            return api.get<HealthStatus>('/health').pipe(
              tap((data) => {
                updateCache('health', {
                  data,
                  lastFetched: Date.now(),
                  state: 'loaded',
                  error: null,
                });
              }),
              catchError((err) => {
                updateCache('health', {
                  state: 'error',
                  error: err.message || 'Failed to load health status',
                });
                return of(null);
              })
            );
          })
        )
      ),
      
      // ======================================================================
      // GPU Status
      // ======================================================================
      loadGpu: rxMethod<void>(
        pipe(
          tap(() => {
            const cached = store.gpu();
            if (cached.state !== 'loading' && isCacheStale(cached, 'gpu')) {
              updateCache('gpu', { state: 'loading' });
            }
          }),
          exhaustMap(() => {
            const cached = store.gpu();
            if (isCacheValid(cached, 'gpu') && !isCacheStale(cached, 'gpu')) {
              return of(null);
            }
            return api.get<GpuStatus>('/gpu/status').pipe(
              tap((data) => {
                updateCache('gpu', {
                  data,
                  lastFetched: Date.now(),
                  state: 'loaded',
                  error: null,
                });
              }),
              catchError((err) => {
                updateCache('gpu', {
                  state: 'error',
                  error: err.message || 'GPU unavailable',
                });
                return of(null);
              })
            );
          })
        )
      ),
      
      // ======================================================================
      // Graph Stats
      // ======================================================================
      loadGraphStats: rxMethod<void>(
        pipe(
          tap(() => {
            const cached = store.graphStats();
            if (cached.state !== 'loading' && isCacheStale(cached, 'graphStats')) {
              updateCache('graphStats', { state: 'loading' });
            }
          }),
          exhaustMap(() => {
            const cached = store.graphStats();
            if (isCacheValid(cached, 'graphStats') && !isCacheStale(cached, 'graphStats')) {
              return of(null);
            }
            return api.get<GraphStats>('/graph/stats').pipe(
              tap((data) => {
                updateCache('graphStats', {
                  data,
                  lastFetched: Date.now(),
                  state: 'loaded',
                  error: null,
                });
              }),
              catchError((err) => {
                updateCache('graphStats', {
                  state: 'error',
                  error: err.message || 'Graph stats unavailable',
                });
                return of(null);
              })
            );
          })
        )
      ),
      
      // ======================================================================
      // Models
      // ======================================================================
      loadModels: rxMethod<void>(
        pipe(
          tap(() => {
            const cached = store.models();
            if (cached.state !== 'loading' && isCacheStale(cached, 'models')) {
              updateCache('models', { state: 'loading' });
            }
          }),
          exhaustMap(() => {
            const cached = store.models();
            if (isCacheValid(cached, 'models') && !isCacheStale(cached, 'models')) {
              return of(null);
            }
            return api.get<ModelInfo[]>('/models/catalog').pipe(
              tap((data) => {
                updateCache('models', {
                  data,
                  lastFetched: Date.now(),
                  state: 'loaded',
                  error: null,
                });
              }),
              catchError((err) => {
                updateCache('models', {
                  state: 'error',
                  error: err.message || 'Failed to load models',
                });
                return of(null);
              })
            );
          })
        )
      ),
      
      // ======================================================================
      // Jobs
      // ======================================================================
      loadJobs: rxMethod<void>(
        pipe(
          tap(() => {
            const cached = store.jobs();
            if (cached.state !== 'loading' && isCacheStale(cached, 'jobs')) {
              updateCache('jobs', { state: 'loading' });
            }
          }),
          exhaustMap(() => {
            const cached = store.jobs();
            if (isCacheValid(cached, 'jobs') && !isCacheStale(cached, 'jobs')) {
              return of(null);
            }
            return api.get<JobResponse[]>('/jobs').pipe(
              tap((data) => {
                updateCache('jobs', {
                  data,
                  lastFetched: Date.now(),
                  state: 'loaded',
                  error: null,
                });
              }),
              catchError((err) => {
                updateCache('jobs', {
                  state: 'error',
                  error: err.message || 'Failed to load jobs',
                });
                return of(null);
              })
            );
          })
        )
      ),
      
      // ======================================================================
      // Mutations
      // ======================================================================
      addJob(job: JobResponse): void {
        const current = store.jobs().data ?? [];
        updateCache('jobs', { data: [job, ...current] });
        toast.success(`Job ${job.id.slice(0, 8)} created`);
      },
      
      updateJobProgress(jobId: string, progress: number, status: string): void {
        const current = store.jobs().data ?? [];
        const updated = current.map((j) =>
          j.id === jobId ? { ...j, progress, status } : j
        );
        updateCache('jobs', { data: updated });
      },
      
      // ======================================================================
      // UI State
      // ======================================================================
      toggleSidebar(): void {
        patchState(store, { sidebarCollapsed: !store.sidebarCollapsed() });
      },
      
      // ======================================================================
      // Bulk Operations
      // ======================================================================
      loadDashboardData(): void {
        this.loadHealth();
        this.loadGpu();
        this.loadGraphStats();
      },
      
      loadModelOptimizerData(): void {
        this.loadModels();
        this.loadJobs();
      },
      
      // ======================================================================
      // Cache Invalidation
      // ======================================================================
      invalidateCache(key: CacheKey): void {
        updateCache(key, { lastFetched: null, state: 'idle' } as any);
      },
      
      forceRefresh(key: CacheKey): void {
        updateCache(key, { lastFetched: null } as any);
        switch (key) {
          case 'health': this.loadHealth(); break;
          case 'gpu': this.loadGpu(); break;
          case 'graphStats': this.loadGraphStats(); break;
          case 'models': this.loadModels(); break;
          case 'jobs': this.loadJobs(); break;
        }
      },

      // ======================================================================
      // WebSockets
      // ======================================================================
      connectWs(): void {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const host = window.location.host;
        const wsUrl = `${protocol}//${host}/api/ws`;

        patchState(store, { wsState: 'connecting' });

        const subject = webSocket({
          url: wsUrl,
          openObserver: {
            next: () => patchState(store, { wsState: 'connected' })
          },
          closeObserver: {
            next: () => patchState(store, { wsState: 'offline' })
          }
        });

        subject.pipe(
          retry({
            delay: (error, retryCount) => {
              patchState(store, { wsState: 'reconnecting' });
              console.warn(`WebSocket disconnected. Reconnect attempt ${retryCount}...`);
              // Exponential backoff capped at 10 seconds
              return timer(Math.min(1000 * Math.pow(2, retryCount), 10000));
            }
          })
        ).subscribe({
          next: (msg: any) => {
            if (msg.type === 'gpu') {
              updateCache('gpu', { data: msg.data, state: 'loaded', lastFetched: Date.now() });
            } else if (msg.type === 'jobs') {
              updateCache('jobs', { data: msg.data, state: 'loaded', lastFetched: Date.now() });
            }
          },
          error: (err) => {
            console.error('WS Fatal Error:', err);
            patchState(store, { wsState: 'error' });
          },
        });
      },
    };
  }),
  withHooks({
    onInit(store, notification = inject(NotificationService)) {
      // Opportunistically request permission
      notification.requestPermission();

      let previousCompletedJobs = new Set<string>();

      effect(() => {
        const jobsData = store.jobs().data;
        if (jobsData) {
          const completedJobs = jobsData.filter(j => j.status === 'completed');
          
          for (const job of completedJobs) {
            if (!previousCompletedJobs.has(job.id)) {
              // Trigger notification!
              notification.notify('Training Job Completed', {
                body: `Job "${job.name || job.id}" has successfully finished.`
              });
              previousCompletedJobs.add(job.id);
            }
          }
        }
      });

      store.connectWs();
    }
  })
);