/**
 * Adaptive UI Architecture — Capture Hooks
 * 
 * Easy-to-use hooks for capturing interactions in components.
 * These provide a clean API for instrumenting existing components.
 */

import { captureService } from './capture-service';
import type { InteractionType, InteractionEvent } from './types';

// ============================================================================
// TYPES
// ============================================================================

export interface CaptureOptions {
  /** Component type (e.g., 'filter', 'table', 'chart') */
  componentType: string;
  /** Unique component instance ID */
  componentId: string;
  /** Additional metadata to include with all events */
  defaultMetadata?: Record<string, unknown>;
}

export interface CaptureHooks {
  /** Capture a click event */
  captureClick: (target: string, metadata?: Record<string, unknown>) => void;
  /** Capture a selection event */
  captureSelect: (target: string, value: unknown, metadata?: Record<string, unknown>) => void;
  /** Capture a filter event */
  captureFilter: (field: string, value: unknown, metadata?: Record<string, unknown>) => void;
  /** Capture a sort event */
  captureSort: (column: string, direction: 'asc' | 'desc', metadata?: Record<string, unknown>) => void;
  /** Capture a navigation event */
  captureNavigate: (destination: string, metadata?: Record<string, unknown>) => void;
  /** Capture a search event */
  captureSearch: (query: string, resultCount?: number, metadata?: Record<string, unknown>) => void;
  /** Capture an expand/collapse event */
  captureExpand: (target: string, expanded: boolean, metadata?: Record<string, unknown>) => void;
  /** Capture a scroll event (debounced) */
  captureScroll: (visibleRange: { start: number; end: number }, metadata?: Record<string, unknown>) => void;
  /** Capture a hover event with duration */
  captureHover: (target: string, durationMs: number, metadata?: Record<string, unknown>) => void;
  /** Capture a generic event */
  capture: (type: InteractionType, target: string, metadata?: Record<string, unknown>) => void;
}

// ============================================================================
// HOOK FACTORY
// ============================================================================

/**
 * Create capture hooks for a component.
 * 
 * @example
 * ```typescript
 * const capture = createCaptureHooks({
 *   componentType: 'filter',
 *   componentId: 'main-filter-panel',
 * });
 * 
 * // In event handlers:
 * onFilterChange(field, value) {
 *   capture.captureFilter(field, value);
 * }
 * ```
 */
export function createCaptureHooks(options: CaptureOptions): CaptureHooks {
  const { componentType, componentId, defaultMetadata = {} } = options;

  const capture = (
    type: InteractionType,
    target: string,
    metadata: Record<string, unknown> = {}
  ): void => {
    captureService.capture({
      type,
      target,
      componentType,
      componentId,
      metadata: { ...defaultMetadata, ...metadata },
    });
  };

  return {
    captureClick: (target, metadata) => capture('click', target, metadata),
    
    captureSelect: (target, value, metadata) => 
      capture('select', target, { value, ...metadata }),
    
    captureFilter: (field, value, metadata) =>
      capture('filter', field, { field, value, ...metadata }),
    
    captureSort: (column, direction, metadata) =>
      capture('sort', column, { column, direction, ...metadata }),
    
    captureNavigate: (destination, metadata) =>
      capture('navigate', destination, { destination, ...metadata }),
    
    captureSearch: (query, resultCount, metadata) =>
      capture('search', 'search-input', { query, resultCount, ...metadata }),
    
    captureExpand: (target, expanded, metadata) =>
      capture(expanded ? 'expand' : 'collapse', target, { expanded, ...metadata }),
    
    captureScroll: (visibleRange, metadata) =>
      capture('scroll', 'viewport', { visibleRange, ...metadata }),
    
    captureHover: (target, durationMs, metadata) =>
      capture('hover', target, { durationMs, ...metadata }),
    
    capture,
  };
}

// ============================================================================
// TIMING HELPERS
// ============================================================================

/**
 * Create a hover tracker that captures hover duration.
 * 
 * @example
 * ```typescript
 * const hoverTracker = createHoverTracker(capture.captureHover);
 * 
 * element.addEventListener('mouseenter', () => hoverTracker.start('button-1'));
 * element.addEventListener('mouseleave', () => hoverTracker.end('button-1'));
 * ```
 */
export function createHoverTracker(
  onHover: (target: string, durationMs: number, metadata?: Record<string, unknown>) => void
): {
  start: (target: string) => void;
  end: (target: string, metadata?: Record<string, unknown>) => void;
} {
  const startTimes: Map<string, number> = new Map();

  return {
    start: (target: string) => {
      startTimes.set(target, Date.now());
    },
    end: (target: string, metadata?: Record<string, unknown>) => {
      const startTime = startTimes.get(target);
      if (startTime) {
        const duration = Date.now() - startTime;
        // Only capture meaningful hovers (> 200ms)
        if (duration > 200) {
          onHover(target, duration, metadata);
        }
        startTimes.delete(target);
      }
    },
  };
}

/**
 * Create a focus tracker that captures focus duration.
 */
export function createFocusTracker(
  onFocus: (target: string, durationMs: number, metadata?: Record<string, unknown>) => void
): {
  start: (target: string) => void;
  end: (target: string, metadata?: Record<string, unknown>) => void;
} {
  return createHoverTracker(onFocus); // Same logic, different semantic
}

