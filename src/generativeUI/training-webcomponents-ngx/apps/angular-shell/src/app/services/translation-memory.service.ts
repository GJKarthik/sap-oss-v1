import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, forkJoin, of, map } from 'rxjs';

export type TMPairType = 'translation' | 'alias' | 'db_field_mapping';

export interface TMDbContext {
  table_name?: string;
  column_name?: string;
  data_type?: string;
}

export interface TMEntry {
  id?: string;
  source_text: string;
  target_text: string;
  source_lang: string;
  target_lang: string;
  category: string;
  is_approved: boolean;
  created_at?: string;
  pair_type?: TMPairType;
  db_context?: TMDbContext;
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

  delete(entryId: string): Observable<void> {
    return this.http.delete<void>(`${this.base}/${entryId}`);
  }

  /** Gets all approved overrides for a specific language pair. */
  getOverrides(sourceLang: string, targetLang: string): Observable<TMEntry[]> {
    return this.list().pipe(
      map((entries) => entries.filter((entry) => (
        entry.source_lang === sourceLang && entry.target_lang === targetLang
      )))
    );
  }

  /** Bulk-save an array of TM entries. Returns per-entry success/failure counts. */
  saveBatch(entries: TMEntry[]): Observable<{ saved: number; failed: number; failedIds: string[] }> {
    if (entries.length === 0) {
      return of({ saved: 0, failed: 0, failedIds: [] });
    }

    const requests = entries.map((entry, idx) =>
      this.save(entry).pipe(
        map(() => ({ success: true, idx })),
        map((r) => r),
      )
    );

    return forkJoin(requests).pipe(
      map((results) => {
        let saved = 0;
        let failed = 0;
        const failedIds: string[] = [];
        results.forEach((r, i) => {
          if (r.success) {
            saved++;
          } else {
            failed++;
            failedIds.push(entries[i].id || String(i));
          }
        });
        return { saved, failed, failedIds };
      })
    );
  }
}
