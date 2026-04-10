import { TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { Router } from '@angular/router';
import { DashboardComponent } from './dashboard.component';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { NavigationAssistantService } from '../../services/navigation-assistant.service';
import { DashboardLayoutService } from '../../services/dashboard-layout.service';
import { AppLinkService } from '../../services/app-link.service';

const MOCK_STORE = {
  health: signal({
    data: {
      status: 'healthy',
      dependencies: {
        database: 'healthy',
        hana_vector: 'healthy',
        vllm_turboquant: 'healthy',
      },
    },
    loading: false,
  }),
  gpu: signal({
    data: {
      gpu_name: 'NVIDIA T4',
      memory_total: 16,
      memory_used: 4,
      utilization: 25,
      cuda_version: '12.2',
    },
    loading: false,
  }),
  isDashboardLoading: signal(false),
  isHealthy: signal(true),
  healthBadge: signal('Positive'),
  gpuUtilization: signal(25),
  trainingPairCount: signal(1200),
  platformNarrative: signal('narrative.healthy'),
  loadDashboardData: jest.fn(),
  forceRefresh: jest.fn(),
};

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

const MOCK_ROUTER = {
  navigate: jest.fn(),
};

const MOCK_I18N = {
  t: (key: string) => key,
  currentLang: () => 'en',
};

const MOCK_NAVIGATION_ASSISTANT = {
  pinnedEntries: () => [],
  recentEntries: () => [],
  suggestedEntries: () => [],
  isPinned: jest.fn(() => false),
};

const MOCK_LAYOUT = {
  orderedWidgets: () => ['hubMap', 'priorityActions', 'quickAccess', 'liveSignals', 'productFamily'],
  isVisible: jest.fn(() => true),
  toggleVisibility: jest.fn(),
  move: jest.fn(),
  reset: jest.fn(),
};

const MOCK_APP_LINKS = {
  navigate: jest.fn(),
};

describe('DashboardComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [DashboardComponent],
      providers: [
        { provide: AppStore, useValue: MOCK_STORE },
        { provide: ToastService, useValue: MOCK_TOAST },
        { provide: Router, useValue: MOCK_ROUTER },
        { provide: I18nService, useValue: MOCK_I18N },
        { provide: NavigationAssistantService, useValue: MOCK_NAVIGATION_ASSISTANT },
        { provide: DashboardLayoutService, useValue: MOCK_LAYOUT },
        { provide: AppLinkService, useValue: MOCK_APP_LINKS },
      ],
    }).compileComponents();

    MOCK_STORE.loadDashboardData.mockClear();
    MOCK_STORE.forceRefresh.mockClear();
    MOCK_ROUTER.navigate.mockClear();
    MOCK_TOAST.info.mockClear();
    MOCK_NAVIGATION_ASSISTANT.isPinned.mockClear();
    MOCK_APP_LINKS.navigate.mockClear();
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

  it('calls forceRefresh and shows refresh feedback', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    fixture.componentInstance.refresh();
    expect(MOCK_STORE.forceRefresh).toHaveBeenCalledTimes(1);
    expect(MOCK_TOAST.info).toHaveBeenCalledWith('dashboard.refreshMsg');
  });

  it('routes the priority actions to live product pages', () => {
    const fixture = TestBed.createComponent(DashboardComponent);
    const cards = fixture.componentInstance.priorityActions();

    fixture.componentInstance.navigateToRoute(cards.find((card) => card.icon === 'process')!.path);
    fixture.componentInstance.navigateToRoute(cards.find((card) => card.icon === 'machine')!.path);
    fixture.componentInstance.navigateToRoute(cards.find((card) => card.icon === 'database')!.path);
    fixture.componentInstance.navigateToRoute(cards.find((card) => card.icon === 'learning-assistant')!.path);

    expect(MOCK_ROUTER.navigate).toHaveBeenNthCalledWith(1, ['/pipeline']);
    expect(MOCK_ROUTER.navigate).toHaveBeenNthCalledWith(2, ['/model-optimizer']);
    expect(MOCK_ROUTER.navigate).toHaveBeenNthCalledWith(3, ['/hana-explorer']);
    expect(MOCK_ROUTER.navigate).toHaveBeenNthCalledWith(4, ['/document-linguist']);
  });

  it('opens SAP AI Experience from the mission hero', () => {
    const fixture = TestBed.createComponent(DashboardComponent);

    fixture.componentInstance.openExperience();

    expect(MOCK_APP_LINKS.navigate).toHaveBeenCalledWith('experience', '/');
  });
});
