import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface VectorStoreCreate {
  table_name: string;
  embedding_model?: string;
}

export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
  status: string;
}

export interface DocumentAddRequest {
  table_name: string;
  documents: string[];
  metadatas?: Array<Record<string, unknown>> | null;
}

export interface DocumentAddResponse {
  documents_added: number;
  status: string;
}

export interface RAGQueryRequest {
  query: string;
  table_name: string;
  k?: number;
}

export interface RAGQueryResponse {
  query: string;
  table_name: string;
  context_docs: unknown[];
  answer: string;
  status: string;
  source: string | null;
}

export interface SimilaritySearchRequest {
  table_name: string;
  query: string;
  k?: number;
}

export interface SimilaritySearchResponse {
  results: unknown[];
  status: string;
}

@Injectable({ providedIn: 'root' })
export class RagService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/rag`;

  listVectorStores(): Observable<VectorStore[]> {
    return this.http.get<VectorStore[]>(`${this.baseUrl}/stores`);
  }

  createVectorStore(body: VectorStoreCreate): Observable<VectorStore> {
    return this.http.post<VectorStore>(`${this.baseUrl}/stores`, body);
  }

  addDocuments(body: DocumentAddRequest): Observable<DocumentAddResponse> {
    return this.http.post<DocumentAddResponse>(`${this.baseUrl}/documents`, body);
  }

  ragQuery(body: RAGQueryRequest): Observable<RAGQueryResponse> {
    return this.query(body);
  }

  query(body: RAGQueryRequest): Observable<RAGQueryResponse> {
    return this.http.post<RAGQueryResponse>(`${this.baseUrl}/query`, body);
  }

  similaritySearch(body: SimilaritySearchRequest): Observable<SimilaritySearchResponse> {
    return this.http.post<SimilaritySearchResponse>(`${this.baseUrl}/similarity-search`, body);
  }
}