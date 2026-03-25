import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export type ServiceStatus = 'healthy' | 'degraded' | 'error' | 'unknown';

export interface DashboardStats {
  services_healthy: number;
  total_services: number;
  active_deployments: number;
  total_deployments: number;
  vector_stores: number;
  documents_indexed: number;
  governance_rules_active: number;
  registered_users: number;
}

export interface ServiceMetrics {
  requests_total: number;
  requests_per_second: number;
  latency_p50_ms: number;
  latency_p99_ms: number;
  error_rate: number;
  status?: ServiceStatus;
  service?: string;
}

export type ServiceMetricsMap = Record<string, ServiceMetrics>;

export interface UsageMetrics {
  total_requests_24h: number;
  total_tokens_24h: number;
  unique_users_24h: number;
  top_models: unknown[];
}

@Injectable({ providedIn: 'root' })
export class MetricsService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/metrics`;

  getDashboardStats(): Observable<DashboardStats> {
    return this.http.get<DashboardStats>(`${this.baseUrl}/dashboard`);
  }

  getServiceMetrics(): Observable<ServiceMetricsMap> {
    return this.http.get<ServiceMetricsMap>(`${this.baseUrl}/services`);
  }

  getUsageMetrics(): Observable<UsageMetrics> {
    return this.http.get<UsageMetrics>(`${this.baseUrl}/usage`);
  }
}