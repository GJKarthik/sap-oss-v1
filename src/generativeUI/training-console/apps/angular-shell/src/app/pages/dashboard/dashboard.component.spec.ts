import { TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { DashboardComponent } from './dashboard.component';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';

const MOCK_STORE = {
  health: signal({ data: { status: 'healthy', service: 'tc', version: '1.0' }, state: 'loaded' as const, lastFetched: Date.now(), error: null }),
  gpu: signal({ data: { gpu_name: 'NVIDIA T4', total_memory_gb: 16, used_memory_gb: 4, free_memory_gb: 12, utilization_percent: 25, temperature_c: 45, driver_version: '535', cuda_version: '12.2' }, state: 'loaded' as const, lastFetched: Date.now(), error: null }),
  graphStats: signal({ data: { available: true, pair_count: 1200 }, state: 'loaded' as const, lastFetched: Date.now(), error: null }),
  jobs: signal({ data: [], state: 'idle' as const, lastFetched: null, error: null }),
  models: signal({ data: [], state: 'idle' as const, lastFetched: null, error: null }),
  isDashboardLoading: signal(false),
  isHealthy: signal(true),
  healthBadge: signal('status-success'),
  gpuMemoryUsed: signal('4.0'),
  gpuMemoryTotal: signal('16.0'),
  gpuUtilization: signal(25),
  trainingPairCount: signal(1200),
  isGraphAvailable: signal(true),
  pendingJobs: signal([]),
  completedJobs: signal([]),
  sidebarCollapsed: signal(false),
  loadDashboardData: jest.fn(),
  forceRefresh: jest.fn(),
  loadHealth: jest.fn(),
  loadGpu: jest.fn(),
  loadGraphStats: jest.fn(),
};

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

describe('DashboardComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [DashboardComponent],
      providers: [
        { provide: AppStore, useValue: MOCK_STORE },
        { provide: ToastService, useValue: MOCK_TOAST },
      ],
    }).compileComponents();

    MOCK_STORE.loadDashboardData.calls.reset();
    MOCK_STORE.forceRefresh.calls.reset();
  });

  it('should create', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    expect(fixture.componentInstance).toBeTruthy();
  });

  it('calls loadDashboardData on init', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    fixture.detectChanges();
    expect(MOCK_STORE.loadDashboardData).toHaveBeenCalledTimes(1);
  });

  it('renders GPU utilization from store', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('25%');
  });

  it('calls forceRefresh on all three keys when refresh() is invoked', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    fixture.componentInstance.refresh();
    expect(MOCK_STORE.forceRefresh).toHaveBeenCalledWith('health');
    expect(MOCK_STORE.forceRefresh).toHaveBeenCalledWith('gpu');
    expect(MOCK_STORE.forceRefresh).toHaveBeenCalledWith('graphStats');
  });
});
