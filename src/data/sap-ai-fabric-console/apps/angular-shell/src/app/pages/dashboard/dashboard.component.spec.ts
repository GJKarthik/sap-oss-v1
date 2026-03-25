import { CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { of } from 'rxjs';

import {
  DashboardStats,
  MetricsService,
  ServiceMetricsMap,
} from '../../services/api/metrics.service';
import { DashboardComponent } from './dashboard.component';

describe('DashboardComponent', () => {
  let fixture: ComponentFixture<DashboardComponent>;
  let component: DashboardComponent;
  let metricsService: {
    getDashboardStats: jest.Mock;
    getServiceMetrics: jest.Mock;
  };

  beforeEach(async () => {
    metricsService = {
      getDashboardStats: jest.fn(),
      getServiceMetrics: jest.fn(),
    };

    await TestBed.configureTestingModule({
      imports: [DashboardComponent],
      providers: [
        { provide: MetricsService, useValue: metricsService },
        provideRouter([]),
      ],
      schemas: [CUSTOM_ELEMENTS_SCHEMA],
    }).compileComponents();
  });

  it('loads dashboard stats and service health from MetricsService', () => {
    const stats: DashboardStats = {
      services_healthy: 1,
      total_services: 2,
      active_deployments: 3,
      total_deployments: 4,
      vector_stores: 5,
      documents_indexed: 1200,
      governance_rules_active: 8,
      registered_users: 42,
    };
    const serviceMetrics: ServiceMetricsMap = {
      'langchain-hana-mcp': {
        requests_total: 100,
        requests_per_second: 2.5,
        latency_p50_ms: 120,
        latency_p99_ms: 450,
        error_rate: 0,
        status: 'healthy',
      },
      'ai-core-streaming-mcp': {
        requests_total: 80,
        requests_per_second: 1.5,
        latency_p50_ms: 140,
        latency_p99_ms: 520,
        error_rate: 0.2,
        status: 'degraded',
      },
    };

    metricsService.getDashboardStats.mockReturnValue(of(stats));
    metricsService.getServiceMetrics.mockReturnValue(of(serviceMetrics));

    fixture = TestBed.createComponent(DashboardComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(metricsService.getDashboardStats).toHaveBeenCalled();
    expect(metricsService.getServiceMetrics).toHaveBeenCalled();
    expect(component.stats).toEqual(stats);
    expect(component.health.langchain?.status).toBe('healthy');
    expect(component.health.streaming?.status).toBe('degraded');
    expect(component.health.overall).toBe('degraded');
    expect(component.getHealthMessage()).toContain('AI Core Streaming');
    expect(fixture.nativeElement.textContent).toContain('Governance');
    expect(fixture.nativeElement.textContent).toContain('Registered Users');
  });

  it('infers healthy status from zero error rates when explicit status is omitted', () => {
    metricsService.getDashboardStats.mockReturnValue(of({
      services_healthy: 2,
      total_services: 2,
      active_deployments: 1,
      total_deployments: 1,
      vector_stores: 1,
      documents_indexed: 20,
      governance_rules_active: 2,
      registered_users: 5,
    } satisfies DashboardStats));
    metricsService.getServiceMetrics.mockReturnValue(of({
      'langchain-hana-mcp': {
        requests_total: 10,
        requests_per_second: 1,
        latency_p50_ms: 10,
        latency_p99_ms: 20,
        error_rate: 0,
      },
      'ai-core-streaming-mcp': {
        requests_total: 12,
        requests_per_second: 1.2,
        latency_p50_ms: 12,
        latency_p99_ms: 24,
        error_rate: 0,
      },
    } satisfies ServiceMetricsMap));

    fixture = TestBed.createComponent(DashboardComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(component.health.langchain?.status).toBe('healthy');
    expect(component.health.streaming?.status).toBe('healthy');
    expect(component.health.overall).toBe('healthy');
  });
});