/**
 * SearchToInsight Service
 *
 * Angular wrapper for SAC Search-to-Insight dialog functionality.
 * Wraps SearchToInsight from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable, inject } from '@angular/core';
import { Subject, Observable } from 'rxjs';
import { SacApiService } from '@sap-oss/sac-ngx-core';

import type {
  SearchToInsightDialogMode,
  SearchToInsightResult,
} from '../types/builtins.types';

@Injectable()
export class SearchToInsightService {
  private readonly api = inject(SacApiService);
  private readonly searchResult$ = new Subject<SearchToInsightResult>();
  private readonly dialogClosed$ = new Subject<void>();
  private dialogOpen = false;
  private mode: SearchToInsightDialogMode = 'both';

  /** Emits when a search/insight result is produced */
  get onResult$(): Observable<SearchToInsightResult> {
    return this.searchResult$.asObservable();
  }

  /** Emits when the dialog is closed */
  get onDialogClose$(): Observable<void> {
    return this.dialogClosed$.asObservable();
  }

  /**
   * Open the Search-to-Insight dialog.
   */
  open(mode?: SearchToInsightDialogMode): void {
    this.mode = mode ?? 'both';
    this.dialogOpen = true;
    this.api.post('/builtins/search-to-insight/open', { mode: this.mode }).catch(() => {
      // Best-effort: dialog state is managed locally even if API call fails
    });
  }

  /**
   * Close the dialog.
   */
  close(): void {
    this.dialogOpen = false;
    this.dialogClosed$.next();
  }

  /**
   * Check if the dialog is currently open.
   */
  isOpen(): boolean {
    return this.dialogOpen;
  }

  /**
   * Get the current dialog mode.
   */
  getMode(): SearchToInsightDialogMode {
    return this.mode;
  }

  /**
   * Set the dialog mode.
   */
  setMode(mode: SearchToInsightDialogMode): void {
    this.mode = mode;
  }

  /**
   * Execute a search query programmatically.
   */
  async search(query: string): Promise<SearchToInsightResult> {
    try {
      const result = await this.api.post<SearchToInsightResult>('/builtins/search-to-insight/search', { query });
      this.searchResult$.next(result);
      return result;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  /**
   * Apply an insight result to the current story.
   */
  async applyInsight(result: SearchToInsightResult): Promise<void> {
    try {
      await this.api.post('/builtins/search-to-insight/apply', result);
      this.searchResult$.next(result);
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  destroy(): void {
    this.searchResult$.complete();
    this.dialogClosed$.complete();
  }
}
