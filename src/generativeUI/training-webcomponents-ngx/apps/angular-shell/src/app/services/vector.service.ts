import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { catchError } from 'rxjs/operators';

export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
  created_at?: string;
}

export interface VectorContextDoc {
  content: string;
  metadata: Record<string, unknown>;
  score: number;
}

export interface VectorQueryResult {
  context_docs: VectorContextDoc[];
  table_name: string;
  query: string;
  answer: string;
  status: string;
  source?: string;
}

export interface VectorAddResult {
  documents_added: number;
  status: string;
}

export interface VectorAnalyticsResult {
  total_revenue: number;
  total_profit: number;
  doc_count: number;
  rows: Array<{
    source: string;
    date: string;
    revenue: number;
    profit: number;
  }>;
}

@Injectable({ providedIn: 'root' })
export class VectorService {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/rag';

  fetchStores(): Observable<VectorStore[]> {
    return this.http.get<VectorStore[]>(`${this.base}/stores`).pipe(
      catchError(() => of([])),
    );
  }

  query(question: string, tableName: string, k = 4): Observable<VectorQueryResult> {
    return this.http.post<VectorQueryResult>(`${this.base}/query`, {
      query: question,
      table_name: tableName,
      k,
    }).pipe(
      catchError(() => of({
        context_docs: [],
        table_name: tableName,
        query: question,
        answer: '',
        status: 'unavailable',
      })),
    );
  }

  addDocuments(
    tableName: string,
    documents: string[],
    metadatas: Record<string, unknown>[],
  ): Observable<VectorAddResult> {
    return this.http.post<VectorAddResult>(`${this.base}/documents`, {
      table_name: tableName,
      documents,
      metadatas,
    }).pipe(
      catchError(() => of({ documents_added: 0, status: 'unavailable' })),
    );
  }

  fetchAnalytics(tableName: string): Observable<VectorAnalyticsResult> {
    return this.http.post<VectorAnalyticsResult>(`${this.base}/analytics`, {
      store: tableName,
    }).pipe(
      catchError(() => of({
        total_revenue: 0,
        total_profit: 0,
        doc_count: 0,
        rows: [],
      })),
    );
  }
}
