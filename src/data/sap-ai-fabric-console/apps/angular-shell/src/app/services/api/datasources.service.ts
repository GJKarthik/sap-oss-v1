import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface DataSource {
  id: string;
  name: string;
  source_type: string;
  connection_status: string;
  config: Record<string, unknown>;
  last_sync: string | null;
}

export interface DataSourceCreateRequest {
  name: string;
  source_type: string;
  config?: Record<string, unknown>;
}

export interface DataSourceListResponse {
  datasources: DataSource[];
  total: number;
}

export interface DataSourceConnectionTestResponse {
  id: string;
  connection_status: string;
}

@Injectable({ providedIn: 'root' })
export class DatasourcesService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/datasources`;

  listDatasources(): Observable<DataSourceListResponse> {
    return this.http.get<DataSourceListResponse>(this.baseUrl);
  }

  createDatasource(body: DataSourceCreateRequest): Observable<DataSource> {
    return this.http.post<DataSource>(this.baseUrl, body);
  }

  getDatasource(datasourceId: string): Observable<DataSource> {
    return this.http.get<DataSource>(`${this.baseUrl}/${datasourceId}`);
  }

  deleteDatasource(datasourceId: string): Observable<void> {
    return this.http.delete<void>(`${this.baseUrl}/${datasourceId}`);
  }

  testConnection(datasourceId: string): Observable<DataSourceConnectionTestResponse> {
    return this.http.post<DataSourceConnectionTestResponse>(`${this.baseUrl}/${datasourceId}/test`, null);
  }
}