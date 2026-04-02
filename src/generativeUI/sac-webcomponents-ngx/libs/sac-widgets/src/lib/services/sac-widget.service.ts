/**
 * SAC Widget Service
 *
 * Service for managing SAC widget lifecycle, visibility, layout, and hierarchy.
 * Derived from sap-sac-webcomponents-ts/src/widgets/Widget base class.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import type { WidgetConfig } from '../types/widget.types';

@Injectable()
export class SacWidgetService {
  private widgets = new Map<string, WidgetConfig>();
  private readonly activeWidget$ = new BehaviorSubject<string | null>(null);

  /** Observable for currently active widget ID */
  get currentWidget$(): Observable<string | null> {
    return this.activeWidget$.asObservable();
  }

  /**
   * Register a widget with its configuration.
   */
  register(widgetId: string, config: WidgetConfig): void {
    this.widgets.set(widgetId, config);
  }

  /**
   * Unregister a widget.
   */
  unregister(widgetId: string): void {
    this.widgets.delete(widgetId);
    if (this.activeWidget$.value === widgetId) {
      this.activeWidget$.next(null);
    }
  }

  /**
   * Get widget configuration.
   */
  getConfig(widgetId: string): WidgetConfig | undefined {
    return this.widgets.get(widgetId);
  }

  /**
   * Update widget configuration.
   */
  updateConfig(widgetId: string, config: Partial<WidgetConfig>): void {
    const existing = this.widgets.get(widgetId);
    if (existing) {
      this.widgets.set(widgetId, { ...existing, ...config });
    }
  }

  /**
   * Set visibility of a widget.
   */
  setVisible(widgetId: string, visible: boolean): void {
    this.updateConfig(widgetId, { visible });
  }

  /**
   * Set enabled state of a widget.
   */
  setEnabled(widgetId: string, enabled: boolean): void {
    this.updateConfig(widgetId, { enabled });
  }

  /**
   * Set the active widget.
   */
  setActive(widgetId: string): void {
    this.activeWidget$.next(widgetId);
  }

  /**
   * Get all registered widget IDs.
   */
  getWidgetIds(): string[] {
    return Array.from(this.widgets.keys());
  }

  /**
   * Destroy service and cleanup.
   */
  destroy(): void {
    this.widgets.clear();
    this.activeWidget$.complete();
  }
}
