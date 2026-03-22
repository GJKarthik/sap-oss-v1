import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface Deployment {
  id: string;
  status: string;
  target_status: string | null;
  scenario_id: string | null;
  creation_time: string;
  details: Record<string, unknown>;
}

export interface DeploymentCreateRequest {
  scenario_id: string;
  configuration?: Record<string, unknown>;
}

export interface DeploymentListResponse {
  resources: Deployment[];
  count: number;
}

export interface DeploymentStatusUpdateResponse {
  id: string;
  target_status: string;
}

@Injectable({ providedIn: 'root' })
export class DeploymentsService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/deployments`;

  listDeployments(): Observable<DeploymentListResponse> {
    return this.http.get<DeploymentListResponse>(this.baseUrl);
  }

  createDeployment(body: DeploymentCreateRequest): Observable<Deployment> {
    return this.http.post<Deployment>(this.baseUrl, body);
  }

  getDeployment(deploymentId: string): Observable<Deployment> {
    return this.http.get<Deployment>(`${this.baseUrl}/${deploymentId}`);
  }

  deleteDeployment(deploymentId: string): Observable<void> {
    return this.http.delete<void>(`${this.baseUrl}/${deploymentId}`);
  }

  updateDeploymentStatus(deploymentId: string, targetStatus: string): Observable<DeploymentStatusUpdateResponse> {
    return this.http.patch<DeploymentStatusUpdateResponse>(
      `${this.baseUrl}/${deploymentId}/status`,
      null,
      { params: { target_status: targetStatus } }
    );
  }
}