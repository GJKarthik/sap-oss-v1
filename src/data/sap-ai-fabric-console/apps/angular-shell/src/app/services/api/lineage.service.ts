import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface GraphQueryRequest {
  cypher: string;
  params?: Record<string, unknown> | null;
}

export interface GraphQueryResponse {
  rows: unknown[];
  row_count: number;
  status: string;
}

export interface GraphIndexRequest {
  vector_stores?: unknown[];
  deployments?: unknown[];
  schemas?: unknown[];
}

export interface GraphIndexResponse {
  stores_indexed: number;
  deployments_indexed: number;
  schemas_indexed: number;
  status: string;
}

export interface GraphSummaryResponse {
  node_count: number;
  edge_count: number;
  node_types: string[];
  edge_types: string[];
}

@Injectable({ providedIn: 'root' })
export class LineageService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/lineage`;

  graphQuery(body: GraphQueryRequest): Observable<GraphQueryResponse> {
    return this.queryGraph(body);
  }

  queryGraph(body: GraphQueryRequest): Observable<GraphQueryResponse> {
    return this.http.post<GraphQueryResponse>(`${this.baseUrl}/query`, body);
  }

  indexEntities(body: GraphIndexRequest): Observable<GraphIndexResponse> {
    return this.indexGraph(body);
  }

  indexGraph(body: GraphIndexRequest): Observable<GraphIndexResponse> {
    return this.http.post<GraphIndexResponse>(`${this.baseUrl}/index`, body);
  }

  getGraphSummary(): Observable<GraphSummaryResponse> {
    return this.http.get<GraphSummaryResponse>(`${this.baseUrl}/graph/summary`);
  }
}