import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { catchError } from 'rxjs/operators';

export interface VectorStore {
  /** Unique identifier / table name used for indexing and querying. */
  table_name: string;
  document_count: number;
  created_at: string;
}

export interface VectorContextDoc {
  content: string;
  metadata: Record<string, unknown>;
  score: number;
}

export interface VectorQueryResult {
  context_docs: VectorContextDoc[];
  table: string;
}

export interface VectorAddResult {
  added: number;
  table: string;
}

@Injectable({ providedIn: 'root' })
export class VectorService {
  private readonly http = inject(HttpClient);

  /** List all available vector stores. */
  fetchStores(): Observable<VectorStore[]> {
    return this.http.get<VectorStore[]>('/api/v1/vector/stores').pipe(
      catchError(() => of([])),
    );
  }

  /** Semantic search against a named vector store. */
  query(question: string, tableName: string): Observable<VectorQueryResult> {
    return this.http.post<VectorQueryResult>('/api/v1/vector/query', {
      query: question,
      table: tableName,
      top_k: 5,
    }).pipe(
      catchError(() => of({ context_docs: [], table: tableName })),
    );
  }

  /** Add documents to a named vector store. */
  addDocuments(
    tableName: string,
    documents: string[],
    metadatas: Record<string, unknown>[],
  ): Observable<VectorAddResult> {
    return this.http.post<VectorAddResult>('/api/v1/vector/add', {
      table: tableName,
      documents,
      metadatas,
    }).pipe(
      catchError(() => of({ added: 0, table: tableName })),
    );
  }
}
