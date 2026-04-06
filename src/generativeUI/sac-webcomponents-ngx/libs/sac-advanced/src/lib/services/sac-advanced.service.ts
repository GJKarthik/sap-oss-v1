/**
 * SAC Advanced Service
 *
 * Service for managing advanced SAC features: SmartDiscovery, Forecast,
 * Export, MultiAction, LinkedAnalysis, DataBindings, Simulation, Alert,
 * BookmarkSet, PageState, FilterState, Commenting, Discussion.
 * Derived from sap-sac-webcomponents-ts/src/advanced.
 */

import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable, Subject } from 'rxjs';
import { SacApiService } from '@sap-oss/sac-ngx-core';

import type {
  SmartDiscoveryInsight,
  ExportOptions,
  DataBindingConfig,
  SimulationScenario,
  AlertCondition,
  BookmarkInfo,
  BookmarkSaveInfo,
  CommentInfo,
  DiscussionMessage,
} from '../types/advanced.types';

@Injectable()
export class SacAdvancedService {
  private readonly api = inject(SacApiService);
  private readonly loading$ = new BehaviorSubject<boolean>(false);
  private readonly error$ = new BehaviorSubject<Error | null>(null);
  private readonly bookmarks$ = new BehaviorSubject<BookmarkInfo[]>([]);
  private readonly alerts$ = new Subject<{ alertId: string; measure: string; value: number }>();

  get isLoading$(): Observable<boolean> {
    return this.loading$.asObservable();
  }

  get lastError$(): Observable<Error | null> {
    return this.error$.asObservable();
  }

  get currentBookmarks$(): Observable<BookmarkInfo[]> {
    return this.bookmarks$.asObservable();
  }

  get alertTriggers$(): Observable<{ alertId: string; measure: string; value: number }> {
    return this.alerts$.asObservable();
  }

  // ---------------------------------------------------------------------------
  // SmartDiscovery
  // ---------------------------------------------------------------------------

  async runSmartDiscovery(dataSource: string): Promise<SmartDiscoveryInsight[]> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.post<SmartDiscoveryInsight[]>('/advanced/smart-discovery', { dataSource });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Forecast
  // ---------------------------------------------------------------------------

  async runForecast(
    dataSource: string,
    measure: string,
    periods: number,
    algorithm?: string,
  ): Promise<unknown> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.post('/advanced/forecast', { dataSource, measure, periods, algorithm });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  async exportStory(options: ExportOptions): Promise<Blob | null> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.post<Blob>('/advanced/export', options);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // MultiAction
  // ---------------------------------------------------------------------------

  async executeMultiAction(actionId: string, parameters?: Record<string, unknown>): Promise<unknown> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.post('/advanced/multi-action', { actionId, parameters });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // LinkedAnalysis
  // ---------------------------------------------------------------------------

  async setLinkedAnalysis(sourceWidgetId: string, targetWidgetIds: string[]): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.post<void>('/advanced/linked-analysis', { sourceWidgetId, targetWidgetIds });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async removeLinkedAnalysis(sourceWidgetId: string): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.delete<void>('/advanced/linked-analysis/' + sourceWidgetId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // DataBindings
  // ---------------------------------------------------------------------------

  async getDataBindings(widgetId: string): Promise<DataBindingConfig | null> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.get<DataBindingConfig>('/advanced/data-bindings/' + widgetId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async setDataBindings(widgetId: string, config: DataBindingConfig): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.put<void>('/advanced/data-bindings/' + widgetId, config);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Simulation
  // ---------------------------------------------------------------------------

  async createScenario(scenario: SimulationScenario): Promise<string> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      const result = await this.api.post<{ id: string }>('/advanced/simulation/scenarios', scenario);
      return result.id;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async runSimulation(scenarioId: string): Promise<unknown> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.post('/advanced/simulation/' + scenarioId + '/run');
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Alerts
  // ---------------------------------------------------------------------------

  async createAlert(alertId: string, condition: AlertCondition): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.post<void>('/advanced/alerts', { alertId, condition });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async removeAlert(alertId: string): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.delete<void>('/advanced/alerts/' + alertId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Bookmarks
  // ---------------------------------------------------------------------------

  async listBookmarks(): Promise<BookmarkInfo[]> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      const bookmarks = await this.api.get<BookmarkInfo[]>('/advanced/bookmarks');
      this.bookmarks$.next(bookmarks);
      return bookmarks;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async saveBookmark(info: BookmarkSaveInfo): Promise<string> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      const result = await this.api.post<{ id: string }>('/advanced/bookmarks', info);
      return result.id;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async applyBookmark(bookmarkId: string): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.post<void>('/advanced/bookmarks/' + bookmarkId + '/apply');
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async deleteBookmark(bookmarkId: string): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.delete<void>('/advanced/bookmarks/' + bookmarkId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // PageState / FilterState
  // ---------------------------------------------------------------------------

  async getPageState(): Promise<Record<string, unknown>> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.get<Record<string, unknown>>('/advanced/page-state');
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async setPageState(state: Record<string, unknown>): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.put<void>('/advanced/page-state', state);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async getFilterState(): Promise<Record<string, unknown>> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.get<Record<string, unknown>>('/advanced/filter-state');
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async setFilterState(filters: Record<string, unknown>): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.put<void>('/advanced/filter-state', filters);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Commenting / Discussion
  // ---------------------------------------------------------------------------

  async getComments(objectId: string): Promise<CommentInfo[]> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.get<CommentInfo[]>('/advanced/comments/' + objectId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async addComment(objectId: string, text: string): Promise<string> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      const result = await this.api.post<{ id: string }>('/advanced/comments/' + objectId, { text });
      return result.id;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async resolveComment(commentId: string): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      await this.api.put<void>('/advanced/comments/' + commentId + '/resolve');
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async getDiscussionMessages(discussionId: string): Promise<DiscussionMessage[]> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      return await this.api.get<DiscussionMessage[]>('/advanced/discussions/' + discussionId);
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  async addDiscussionMessage(discussionId: string, text: string): Promise<string> {
    this.loading$.next(true);
    this.error$.next(null);
    try {
      const result = await this.api.post<{ id: string }>('/advanced/discussions/' + discussionId, { text });
      return result.id;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.error$.next(err);
      throw err;
    } finally {
      this.loading$.next(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  destroy(): void {
    this.loading$.complete();
    this.error$.complete();
    this.bookmarks$.complete();
    this.alerts$.complete();
  }
}
