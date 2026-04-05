import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
  created_at?: string;
}

export interface VectorQueryResponse {
  query: string;
  table_name: string;
  context_docs: any[];
  answer: string;
  status: string;
  source?: string;
}

@Injectable({
  providedIn: 'root'
})
export class VectorService {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/rag';

  fetchStores(): Observable<VectorStore[]> {
    return this.http.get<VectorStore[]>(`${this.base}/stores`);
  }

  createStore(tableName: string, embeddingModel = 'default'): Observable<VectorStore> {
    return this.http.post<VectorStore>(`${this.base}/stores`, {
      table_name: tableName,
      embedding_model: embeddingModel
    });
  }

  addDocuments(tableName: string, documents: string[], metadatas?: any[]): Observable<{ documents_added: number; status: string }> {
    return this.http.post<{ documents_added: number; status: string }>(`${this.base}/documents`, {
      table_name: tableName,
      documents,
      metadatas
    });
  }

  query(query: string, tableName: string, k = 4): Observable<VectorQueryResponse> {
    return this.http.post<VectorQueryResponse>(`${this.base}/query`, {
      query,
      table_name: tableName,
      k
    });
  }

  similaritySearch(tableName: string, query: string, k = 4): Observable<{ results: any[]; status: string }> {
    return this.http.post<{ results: any[]; status: string }>(`${this.base}/similarity-search`, {
      table_name: tableName,
      query,
      k
    });
  }
}
