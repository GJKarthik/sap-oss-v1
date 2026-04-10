import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { AppStore, GpuTelemetry, HealthStatus } from './app.store';
import { AppMode } from '../shared/utils/mode.types';
import { MODE_STORAGE_KEY, DEFAULT_MODE } from '../shared/utils/mode.config';

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

  // ── Mode signal tests ──────────────────────────────────────────────

  describe('mode state', () => {
    beforeEach(() => {
      localStorage.clear();
    });

    it('initializes with default mode (chat)', () => {
      expect(store.activeMode()).toBe('chat');
    });

    it('setMode updates activeMode signal', () => {
      store.setMode('cowork');
      expect(store.activeMode()).toBe('cowork');

      store.setMode('training');
      expect(store.activeMode()).toBe('training');
    });

    it('setMode persists to localStorage', () => {
      store.setMode('training');
      expect(localStorage.getItem(MODE_STORAGE_KEY)).toBe('training');
    });

    it('modeConfig computed returns correct config for active mode', () => {
      store.setMode('chat');
      expect(store.modeConfig().id).toBe('chat');
      expect(store.modeConfig().icon).toBe('discussion-2');

      store.setMode('cowork');
      expect(store.modeConfig().id).toBe('cowork');
      expect(store.modeConfig().icon).toBe('collaborate');

      store.setMode('training');
      expect(store.modeConfig().id).toBe('training');
      expect(store.modeConfig().icon).toBe('process');
    });

    it('modePills computed returns mode-specific pills', () => {
      store.setMode('chat');
      const chatPills = store.modePills();
      expect(chatPills.length).toBe(2);
      expect(chatPills.map(p => p.action)).toEqual(['ask', 'explain']);

      store.setMode('cowork');
      const coworkPills = store.modePills();
      expect(coworkPills.length).toBe(3);
      expect(coworkPills.map(p => p.action)).toContain('propose');

      store.setMode('training');
      const trainingPills = store.modePills();
      expect(trainingPills.length).toBe(3);
      expect(trainingPills.map(p => p.action)).toContain('run');
    });

    it('modeSystemPrompt computed changes with mode', () => {
      store.setMode('chat');
      expect(store.modeSystemPrompt()).toContain('helpful');

      store.setMode('cowork');
      expect(store.modeSystemPrompt()).toContain('collaborative');

      store.setMode('training');
      expect(store.modeSystemPrompt()).toContain('autonomous');
    });

    it('modeConfirmationLevel computed changes with mode', () => {
      store.setMode('chat');
      expect(store.modeConfirmationLevel()).toBe('always');

      store.setMode('cowork');
      expect(store.modeConfirmationLevel()).toBe('destructive-only');

      store.setMode('training');
      expect(store.modeConfirmationLevel()).toBe('never');
    });

    it('persists mode to localStorage and reads it back', () => {
      store.setMode('training');
      expect(localStorage.getItem(MODE_STORAGE_KEY)).toBe('training');

      store.setMode('cowork');
      expect(localStorage.getItem(MODE_STORAGE_KEY)).toBe('cowork');

      store.setMode('chat');
      expect(localStorage.getItem(MODE_STORAGE_KEY)).toBe('chat');
    });
  });
});
