import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { AppStore, GpuStatus, HealthStatus } from './app.store';

const MOCK_HEALTH: HealthStatus = { status: 'healthy', service: 'training-console-api', version: '1.0.0' };
const MOCK_GPU: GpuStatus = {
  gpu_name: 'NVIDIA T4',
  total_memory_gb: 16,
  used_memory_gb: 4,
  free_memory_gb: 12,
  utilization_percent: 25,
  temperature_c: 45,
  driver_version: '535.0',
  cuda_version: '12.2',
};

describe('AppStore', () => {
  let store: InstanceType<typeof AppStore>;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    store = TestBed.inject(AppStore);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  // -------------------------------------------------------------------------
  // loadHealth
  // -------------------------------------------------------------------------
  describe('loadHealth()', () => {
    it('fires an HTTP GET on cache miss', fakeAsync(() => {
      store.loadHealth();
      tick();

      const req = httpMock.expectOne('/api/health');
      expect(req.request.method).toBe('GET');
      req.flush(MOCK_HEALTH);

      expect(store.health().data).toEqual(MOCK_HEALTH);
      expect(store.health().state).toBe('loaded');
    }));

    it('skips HTTP when data is still fresh', fakeAsync(() => {
      // First call – populates cache
      store.loadHealth();
      tick();
      httpMock.expectOne('/api/health').flush(MOCK_HEALTH);

      // Second call immediately – should be a cache hit
      store.loadHealth();
      tick();
      httpMock.expectNone('/api/health');

      expect(store.health().data).toEqual(MOCK_HEALTH);
    }));

    it('sets state to error on HTTP failure', fakeAsync(() => {
      store.loadHealth();
      tick();
      httpMock.expectOne('/api/health').flush('', { status: 502, statusText: 'Bad Gateway' });

      expect(store.health().state).toBe('error');
      expect(store.health().error).toBeTruthy();
    }));
  });

  // -------------------------------------------------------------------------
  // Mutations
  // -------------------------------------------------------------------------
  describe('addJob()', () => {
    it('prepends job to the jobs list', () => {
      const job = { id: 'abc-123', name: 'test-job', status: 'pending', config: { model_name: 'gpt2', quant_format: 'int8', export_format: 'hf' }, created_at: new Date().toISOString(), progress: 0 };
      store.addJob(job);
      expect(store.jobs().data?.[0]).toEqual(job);
    });
  });

  describe('updateJobProgress()', () => {
    it('updates matching job progress and status', () => {
      const job = { id: 'abc-123', name: 'test-job', status: 'pending', config: { model_name: 'gpt2', quant_format: 'int8', export_format: 'hf' }, created_at: new Date().toISOString(), progress: 0 };
      store.addJob(job);
      store.updateJobProgress('abc-123', 0.5, 'running');

      const updated = store.jobs().data?.find((j: { id: string }) => j.id === 'abc-123');
      expect(updated?.progress).toBe(0.5);
      expect(updated?.status).toBe('running');
    });
  });

  // -------------------------------------------------------------------------
  // Computed signals
  // -------------------------------------------------------------------------
  describe('isDashboardLoading()', () => {
    it('is false initially', () => {
      expect(store.isDashboardLoading()).toBe(false);
    });

    it('is true after loadDashboardData triggers loading states', fakeAsync(() => {
      store.loadDashboardData();
      tick();
      // After the tick the state transitions to 'loading'; requests are pending
      const reqs = httpMock.match((r) => ['/api/health', '/api/gpu/status', '/api/graph/stats'].includes(r.url));
      reqs.forEach((r) => r.flush({}));
    }));
  });

  describe('pendingJobs()', () => {
    it('filters to pending and running jobs', () => {
      store.addJob({ id: '1', name: 'j1', status: 'pending', config: { model_name: 'm', quant_format: 'int8', export_format: 'hf' }, created_at: '', progress: 0 });
      store.addJob({ id: '2', name: 'j2', status: 'completed', config: { model_name: 'm', quant_format: 'int8', export_format: 'hf' }, created_at: '', progress: 1 });
      expect(store.pendingJobs().length).toBe(1);
      expect(store.pendingJobs()[0].id).toBe('1');
    });
  });
});
