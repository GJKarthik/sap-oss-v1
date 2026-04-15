import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';

import { AnalyticsComponent } from './analytics.component';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { AppLinkService } from '../../services/app-link.service';

const API = '/api';

describe('AnalyticsComponent', () => {
  let fixture: ComponentFixture<AnalyticsComponent>;
  let component: AnalyticsComponent;
  let httpMock: HttpTestingController;

  const i18n = {
    t: (key: string) => key,
    isRtl: jest.fn(() => false),
  };
  const toast = {
    error: jest.fn(),
  };
  const appLinks = {
    appDisplayNameKey: jest.fn(() => 'nav.training'),
    targetLabelKey: jest.fn(() => null),
    navigate: jest.fn(),
  };

  function flushMetricsLoad(): void {
    httpMock.expectOne((req) =>
      req.url === `${API}/governance/metrics/overview`
      && req.params.get('window') === '30'
      && req.params.get('workflow_type') === ''
      && req.params.get('team') === '',
    ).flush({
      window_days: 30,
      workflow_type: '',
      team: '',
      total_runs: 12,
      gate_pass_rate: 83.3,
      blocked_run_count: 2,
      run_success_rate: 75,
      approval_latency_sec_avg: 5400,
      evaluation_completeness_rate: 92.5,
    });
    httpMock.expectOne((req) =>
      req.url === `${API}/governance/metrics/trends`
      && req.params.get('window') === '30'
      && req.params.get('workflow_type') === ''
      && req.params.get('team') === '',
    ).flush({
      window_days: 30,
      rows: [
        {
          date: '2026-04-13',
          runs: 5,
          blocked_runs: 1,
          completed_runs: 4,
          gate_passed_runs: 4,
          pending_approvals: 1,
          gate_pass_rate: 80,
          run_success_rate: 75,
        },
        {
          date: '2026-04-14',
          runs: 7,
          blocked_runs: 1,
          completed_runs: 6,
          gate_passed_runs: 6,
          pending_approvals: 0,
          gate_pass_rate: 85.7,
          run_success_rate: 85.7,
        },
      ],
    });
  }

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AnalyticsComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: I18nService, useValue: i18n },
        { provide: ToastService, useValue: toast },
        { provide: AppLinkService, useValue: appLinks },
      ],
    })
      .overrideComponent(AnalyticsComponent, {
        add: { schemas: [NO_ERRORS_SCHEMA] },
      })
      .compileComponents();

    fixture = TestBed.createComponent(AnalyticsComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    toast.error.mockClear();
    i18n.isRtl.mockClear();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('loads governance metrics on init and computes chart bars', fakeAsync(() => {
    fixture.detectChanges();
    flushMetricsLoad();
    tick();
    fixture.detectChanges();

    expect(component.overview()?.total_runs).toBe(12);
    expect(component.trends()?.rows).toHaveLength(2);
    expect(component.chartBars()).toEqual([
      { label: '04-13', gateH: 144, successH: 135 },
      { label: '04-14', gateH: 154.26, successH: 154.26 },
    ]);
    expect(component.formatSeconds(5400)).toBe('1.5h');
    expect(fixture.nativeElement.textContent).toContain('Gate pass rate');
  }));

  it('uses the selected filters when loading metrics', fakeAsync(() => {
    fixture.detectChanges();
    flushMetricsLoad();
    tick();

    component.workflowType = 'deployment';
    component.teamFilter = 'platform';
    component.windowDays = 7;
    component.loadData();

    httpMock.expectOne((req) =>
      req.url === `${API}/governance/metrics/overview`
      && req.params.get('window') === '7'
      && req.params.get('workflow_type') === 'deployment'
      && req.params.get('team') === 'platform',
    ).flush({
      window_days: 7,
      workflow_type: 'deployment',
      team: 'platform',
      total_runs: 2,
      gate_pass_rate: 100,
      blocked_run_count: 0,
      run_success_rate: 100,
      approval_latency_sec_avg: 300,
      evaluation_completeness_rate: 100,
    });
    httpMock.expectOne((req) =>
      req.url === `${API}/governance/metrics/trends`
      && req.params.get('window') === '7'
      && req.params.get('workflow_type') === 'deployment'
      && req.params.get('team') === 'platform',
    ).flush({
      window_days: 7,
      rows: [
        {
          date: '2026-04-15',
          runs: 2,
          blocked_runs: 0,
          completed_runs: 2,
          gate_passed_runs: 2,
          pending_approvals: 0,
          gate_pass_rate: 100,
          run_success_rate: 100,
        },
      ],
    });
    tick();

    expect(component.overview()?.workflow_type).toBe('deployment');
    expect(component.overview()?.team).toBe('platform');
    expect(component.barWidth()).toBe(120);
  }));
});
