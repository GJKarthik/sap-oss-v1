/**
 * Adaptive UI Architecture — Angular Adaptation Service
 * 
 * Angular service for consuming adaptation decisions.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';
import { map, distinctUntilChanged } from 'rxjs/operators';
import { adaptationCoordinator } from '../coordinator';
import type { 
  AdaptationDecision, 
  LayoutAdaptation, 
  ContentAdaptation, 
  InteractionAdaptation 
} from '../types';

@Injectable({
  providedIn: 'root',
})
export class AdaptationService implements OnDestroy {
  private decision$ = new BehaviorSubject<AdaptationDecision | null>(
    adaptationCoordinator.getCurrentDecision()
  );
  
  private unsubscribe: (() => void) | null = null;
  
  constructor() {
    this.unsubscribe = adaptationCoordinator.subscribe((decision) => {
      this.decision$.next(decision);
    });
  }
  
  ngOnDestroy(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
    }
  }
  
  // ============================================================================
  // OBSERVABLES
  // ============================================================================
  
  /** Get full adaptation decision */
  getDecision(): Observable<AdaptationDecision | null> {
    return this.decision$.asObservable();
  }
  
  /** Get current decision synchronously */
  getCurrentDecision(): AdaptationDecision | null {
    return this.decision$.value;
  }
  
  /** Get layout adaptations */
  getLayout(): Observable<LayoutAdaptation> {
    return this.decision$.pipe(
      map((d: AdaptationDecision | null) => d?.layout || this.getDefaultLayout()),
      distinctUntilChanged((a: LayoutAdaptation, b: LayoutAdaptation) => JSON.stringify(a) === JSON.stringify(b))
    );
  }

  /** Get content adaptations */
  getContent(): Observable<ContentAdaptation> {
    return this.decision$.pipe(
      map((d: AdaptationDecision | null) => d?.content || this.getDefaultContent()),
      distinctUntilChanged((a: ContentAdaptation, b: ContentAdaptation) => JSON.stringify(a) === JSON.stringify(b))
    );
  }

  /** Get interaction adaptations */
  getInteraction(): Observable<InteractionAdaptation> {
    return this.decision$.pipe(
      map((d: AdaptationDecision | null) => d?.interaction || this.getDefaultInteraction()),
      distinctUntilChanged((a: InteractionAdaptation, b: InteractionAdaptation) => JSON.stringify(a) === JSON.stringify(b))
    );
  }

  /** Get confidence level */
  getConfidence(): Observable<number> {
    return this.decision$.pipe(
      map((d: AdaptationDecision | null) => d?.confidence || 0),
      distinctUntilChanged()
    );
  }
  
  // ============================================================================
  // OVERRIDES
  // ============================================================================
  
  /** Set a user override */
  setOverride(key: string, value: unknown): void {
    adaptationCoordinator.setOverride(key, value);
  }
  
  /** Clear a user override */
  clearOverride(key: string): void {
    adaptationCoordinator.clearOverride(key);
  }
  
  /** Clear all user overrides */
  clearAllOverrides(): void {
    adaptationCoordinator.clearAllOverrides();
  }
  
  /** Force re-adaptation */
  forceAdapt(): void {
    adaptationCoordinator.forceAdapt();
  }
  
  // ============================================================================
  // CSS HELPERS
  // ============================================================================
  
  /** Get CSS variables for SSR or inline styles */
  getCssVariables(): Record<string, string> {
    return adaptationCoordinator.getCssVariablesObject();
  }
  
  /** Get density class name */
  getDensityClass(): Observable<string> {
    return this.getLayout().pipe(
      map((layout: LayoutAdaptation) => `density-${layout.density}`)
    );
  }

  /** Get spacing value in pixels */
  getSpacing(multiplier = 1): Observable<number> {
    return this.getLayout().pipe(
      map((layout: LayoutAdaptation) => layout.spacingScale * 8 * multiplier)
    );
  }
  
  // ============================================================================
  // DEFAULTS
  // ============================================================================
  
  private getDefaultLayout(): LayoutAdaptation {
    return {
      density: 'comfortable',
      gridColumns: 12,
      spacingScale: 1,
      sidebarState: 'expanded',
      panelOrder: [],
      autoExpandPanels: [],
      autoCollapsePanels: [],
    };
  }
  
  private getDefaultContent(): ContentAdaptation {
    return {
      visibleColumns: [],
      columnOrder: [],
      pageSize: 25,
      preAppliedFilters: {},
      suggestedFilters: [],
      preloadData: [],
    };
  }
  
  private getDefaultInteraction(): InteractionAdaptation {
    return {
      touchTargetScale: 1,
      enableKeyboardShortcuts: false,
      showShortcutHints: false,
      enableDragDrop: true,
      hoverDelayMs: 200,
      tooltipDelayMs: 500,
      animationScale: 1,
    };
  }
}

