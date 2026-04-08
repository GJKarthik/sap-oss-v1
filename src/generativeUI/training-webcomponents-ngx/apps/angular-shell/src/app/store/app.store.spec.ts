import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { AppStore, GpuTelemetry, HealthStatus } from './app.store';

const MOCK_HEALTH: HealthStatus = {
  status: 'healthy',
  dependencies: {
    database: 'healthy',
    hana_vector: 'healthy',
    vllm_turboquant: 'healthy',
  },
};

const MOCK_GPU: GpuTelemetry = {
  gpu_name: 'NVIDIA T4',
  memory_total: 16,
  memory_used: 4,
  utilization: 25,
  cuda_version: '12.2',
};

describe('AppStore', () => {
  let store: InstanceType<typeof AppStore>;
  let httpMock: HttpTestingController;

  function flushDashboardRequests(
    health: HealthStatus = MOCK_HEALTH,
    gpu: GpuTelemetry = MOCK_GPU,
  ): void {
    httpMock.expectOne('/api/health').flush(health);
    httpMock.expectOne('/api/gpu/status').flush(gpu);
  }

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });

    store = TestBed.inject(AppStore);
    httpMock = TestBed.inject(HttpTestingController);
    flushDashboardRequests();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('loads dashboard telemetry on init', () => {
    expect(store.health().data).toEqual(MOCK_HEALTH);
    expect(store.gpu().data).toEqual(MOCK_GPU);
    expect(store.isHealthy()).toBe(true);
    expect(store.healthBadge()).toBe('Positive');
    expect(store.gpuUtilization()).toBe(25);
    expect(store.trainingPairCount()).toBe(13952);
  });

  it('computes the platform narrative from health and pipeline state', () => {
    expect(store.platformNarrative()).toBe('narrative.healthy');

    store.setPipelineState('running');

    expect(store.platformNarrative()).toBe('narrative.running');
  });

  it('refreshes telemetry and reflects HANA vector degradation', () => {
    const degradedHealth: HealthStatus = {
      status: 'degraded',
      dependencies: {
        ...MOCK_HEALTH.dependencies,
        hana_vector: 'offline',
      },
    };
    const busyGpu: GpuTelemetry = {
      ...MOCK_GPU,
      utilization: 63,
    };

    store.forceRefresh();
    flushDashboardRequests(degradedHealth, busyGpu);

    expect(store.health().data).toEqual(degradedHealth);
    expect(store.gpuUtilization()).toBe(63);
    expect(store.pipelineState()).toBe('error');
    expect(store.platformNarrative()).toBe('narrative.hanaOffline');
    expect(store.healthBadge()).toBe('Negative');
  });
});
