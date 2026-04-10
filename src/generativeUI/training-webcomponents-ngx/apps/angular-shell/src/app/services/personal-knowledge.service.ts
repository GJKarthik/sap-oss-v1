import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, of, switchMap, map } from 'rxjs';

import { environment } from '../../environments/environment';

export interface PersonalKnowledgeBase {
  id: string;
  owner_id: string;
  name: string;
  slug: string;
  description: string;
  embedding_model: string;
  documents_added: number;
  wiki_pages: number;
  created_at: string;
  updated_at: string;
  storage_backend: string;
}

export interface PersonalKnowledgeContextDoc {
  id: string;
  content: string;
  metadata: Record<string, unknown>;
  score: number;
}

export interface PersonalKnowledgeQueryResult {
  knowledge_base_id: string;
  owner_id: string;
  query: string;
  answer: string;
  context_docs: PersonalKnowledgeContextDoc[];
  suggested_wiki_page?: string | null;
  source: string;
  status: string;
}

export interface PersonalWikiPage {
  slug: string;
  title: string;
  content: string;
  generated: boolean;
  created_at: string;
  updated_at: string;
}

export interface PersonalKnowledgeGraphSummary {
  node_count: number;
  edge_count: number;
  node_types: Array<{ type: string; count: number }>;
  edge_types: Array<{ type: string; count: number }>;
  status: string;
}

export interface PersonalKnowledgeGraphQueryResult {
  rows: Array<Record<string, unknown>>;
  row_count: number;
  status: string;
}

@Injectable({ providedIn: 'root' })
export class PersonalKnowledgeService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/knowledge`;

  listBases(ownerId?: string): Observable<PersonalKnowledgeBase[]> {
    const params = ownerId?.trim()
      ? new HttpParams().set('owner_id', ownerId.trim())
      : new HttpParams();
    return this.http.get<PersonalKnowledgeBase[]>(`${this.baseUrl}/bases`, { params });
  }

  createBase(input: {
    name: string;
    description?: string;
    embeddingModel?: string;
    ownerId?: string;
  }): Observable<PersonalKnowledgeBase> {
    return this.http.post<PersonalKnowledgeBase>(`${this.baseUrl}/bases`, {
      ...(input.ownerId?.trim() ? { owner_id: input.ownerId.trim() } : {}),
      name: input.name,
      description: input.description ?? '',
      embedding_model: input.embeddingModel ?? 'default',
    });
  }

  ensureBase(input: {
    name: string;
    description?: string;
    embeddingModel?: string;
    ownerId?: string;
  }): Observable<PersonalKnowledgeBase> {
    return this.listBases(input.ownerId).pipe(
      map((bases) => bases.find((base) => base.name.trim().toLowerCase() === input.name.trim().toLowerCase()) ?? null),
      switchMap((existing) => existing
        ? of(existing)
        : this.createBase({
            name: input.name,
            description: input.description,
            embeddingModel: input.embeddingModel,
            ownerId: input.ownerId,
          })),
    );
  }

  addDocuments(
    knowledgeBaseId: string,
    documents: string[],
    metadatas?: Record<string, unknown>[],
    ownerId?: string,
  ): Observable<{ knowledge_base_id: string; documents_added: number; wiki_pages_updated: number; status: string; storage_backend: string }> {
    return this.http.post<{ knowledge_base_id: string; documents_added: number; wiki_pages_updated: number; status: string; storage_backend: string }>(
      `${this.baseUrl}/bases/${knowledgeBaseId}/documents`,
      {
        ...(ownerId?.trim() ? { owner_id: ownerId.trim() } : {}),
        documents,
        metadatas,
      },
    );
  }

  queryBase(
    knowledgeBaseId: string,
    query: string,
    k = 4,
    ownerId?: string,
  ): Observable<PersonalKnowledgeQueryResult> {
    return this.http.post<PersonalKnowledgeQueryResult>(`${this.baseUrl}/bases/${knowledgeBaseId}/query`, {
      ...(ownerId?.trim() ? { owner_id: ownerId.trim() } : {}),
      query,
      k,
    });
  }

  listWikiPages(knowledgeBaseId: string, ownerId?: string): Observable<PersonalWikiPage[]> {
    const params = ownerId?.trim()
      ? new HttpParams().set('owner_id', ownerId.trim())
      : new HttpParams();
    return this.http.get<PersonalWikiPage[]>(`${this.baseUrl}/bases/${knowledgeBaseId}/wiki`, { params });
  }

  saveWikiPage(
    knowledgeBaseId: string,
    page: { slug: string; title: string; content: string },
    ownerId?: string,
  ): Observable<PersonalWikiPage> {
    return this.http.put<PersonalWikiPage>(`${this.baseUrl}/bases/${knowledgeBaseId}/wiki/${page.slug}`, {
      ...(ownerId?.trim() ? { owner_id: ownerId.trim() } : {}),
      title: page.title,
      content: page.content,
    });
  }

  getGraphSummary(baseId?: string, ownerId?: string): Observable<PersonalKnowledgeGraphSummary> {
    let params = new HttpParams();
    if (ownerId?.trim()) {
      params = params.set('owner_id', ownerId.trim());
    }
    if (baseId) {
      params = params.set('base_id', baseId);
    }
    return this.http.get<PersonalKnowledgeGraphSummary>(`${this.baseUrl}/graph/summary`, { params });
  }

  queryGraph(
    query: string,
    options?: { baseId?: string; limit?: number; ownerId?: string },
  ): Observable<PersonalKnowledgeGraphQueryResult> {
    return this.http.post<PersonalKnowledgeGraphQueryResult>(`${this.baseUrl}/graph/query`, {
      ...(options?.ownerId?.trim() ? { owner_id: options.ownerId.trim() } : {}),
      query,
      base_id: options?.baseId ?? null,
      limit: options?.limit ?? 40,
    });
  }
}
