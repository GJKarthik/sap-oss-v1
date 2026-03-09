/**
 * SearchToInsight Service
 *
 * Angular wrapper for SAC Search-to-Insight dialog functionality.
 * Wraps SearchToInsight from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';
import { Subject, Observable } from 'rxjs';

import type {
  SearchToInsightDialogMode,
  SearchToInsightResult,
} from '../types/builtins.types';

@Injectable()
export class SearchToInsightService {
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
    // Placeholder — delegates to SAC REST API
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
    // Placeholder — delegates to SAC REST API
    const result: SearchToInsightResult = { query };
    this.searchResult$.next(result);
    return result;
  }

  /**
   * Apply an insight result to the current story.
   */
  async applyInsight(result: SearchToInsightResult): Promise<void> {
    // Placeholder — delegates to SAC REST API
    this.searchResult$.next(result);
  }

  destroy(): void {
    this.searchResult$.complete();
    this.dialogClosed$.complete();
  }
}
