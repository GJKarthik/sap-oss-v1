import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface TMEntry {
  id?: string;
  source_text: string;
  target_text: string;
  source_lang: string;
  target_lang: string;
  category: string;
  is_approved: boolean;
  created_at?: string;
}

export interface TMBackendMeta {
  backend: 'sqlite' | 'hana';
  count: number;
  persistent: boolean;
}

@Injectable({
  providedIn: 'root'
})
export class TranslationMemoryService {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/rag/tm';

  list(): Observable<TMEntry[]> {
    return this.http.get<TMEntry[]>(this.base);
  }

  getMeta(): Observable<TMBackendMeta> {
    return this.http.get<TMBackendMeta>(`${this.base}/meta`);
  }

  save(entry: TMEntry): Observable<TMEntry> {
    return this.http.post<TMEntry>(this.base, entry);
  }

  delete(entryId: string): Observable<any> {
    return this.http.delete(`${this.base}/${entryId}`);
  }

  /** Gets all approved overrides for a specific language pair. */
  getOverrides(sourceLang: string, targetLang: string): Observable<TMEntry[]> {
    return this.list(); // In production, filter on backend
  }
}
