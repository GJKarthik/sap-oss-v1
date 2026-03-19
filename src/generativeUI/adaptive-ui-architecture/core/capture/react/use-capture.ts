/**
 * Adaptive UI Architecture — React Capture Hooks
 * 
 * React hooks for capturing interactions.
 * Framework-agnostic core, React-specific hooks here.
 */

import { useCallback, useRef, useEffect, useMemo } from 'react';
import { captureService } from '../capture-service';
import type { InteractionType, InteractionEvent } from '../types';
import type { CaptureHooks } from '../capture-hooks';

// ============================================================================
// TYPES
// ============================================================================

interface UseCaptureOptions {
  componentType: string;
  componentId: string;
  defaultMetadata?: Record<string, unknown>;
  /** Auto-capture certain events on mount */
  autoCaptureMount?: boolean;
}

// ============================================================================
// MAIN HOOK
// ============================================================================

/**
 * React hook for capturing user interactions.
 * 
 * @example
 * ```tsx
 * function FilterPanel() {
 *   const capture = useCapture({
 *     componentType: 'filter',
 *     componentId: 'main-filter',
 *   });
 * 
 *   const handleFilterChange = (field: string, value: unknown) => {
 *     capture.captureFilter(field, value);
 *     // ... rest of handler
 *   };
 * 
 *   return <div {...capture.getElementProps()}> ... </div>;
 * }
 * ```
 */
export function useCapture(options: UseCaptureOptions): CaptureHooks & {
  getElementProps: () => {
    onClick: (e: React.MouseEvent) => void;
    onFocus: (e: React.FocusEvent) => void;
    onBlur: (e: React.FocusEvent) => void;
  };
} {
  const { componentType, componentId, defaultMetadata = {} } = options;
  const focusStartRef = useRef<number | null>(null);

  const capture = useCallback(
    (type: InteractionType, target: string, metadata: Record<string, unknown> = {}) => {
      captureService.capture({
        type,
        target,
        componentType,
        componentId,
        metadata: { ...defaultMetadata, ...metadata },
      });
    },
    [componentType, componentId, defaultMetadata]
  );

  const captureClick = useCallback(
    (target: string, metadata?: Record<string, unknown>) => capture('click', target, metadata),
    [capture]
  );

  const captureSelect = useCallback(
    (target: string, value: unknown, metadata?: Record<string, unknown>) =>
      capture('select', target, { value, ...metadata }),
    [capture]
  );

  const captureFilter = useCallback(
    (field: string, value: unknown, metadata?: Record<string, unknown>) =>
      capture('filter', field, { field, value, ...metadata }),
    [capture]
  );

  const captureSort = useCallback(
    (column: string, direction: 'asc' | 'desc', metadata?: Record<string, unknown>) =>
      capture('sort', column, { column, direction, ...metadata }),
    [capture]
  );

  const captureNavigate = useCallback(
    (destination: string, metadata?: Record<string, unknown>) =>
      capture('navigate', destination, { destination, ...metadata }),
    [capture]
  );

  const captureSearch = useCallback(
    (query: string, resultCount?: number, metadata?: Record<string, unknown>) =>
      capture('search', 'search-input', { query, resultCount, ...metadata }),
    [capture]
  );

  const captureExpand = useCallback(
    (target: string, expanded: boolean, metadata?: Record<string, unknown>) =>
      capture(expanded ? 'expand' : 'collapse', target, { expanded, ...metadata }),
    [capture]
  );

  const captureScroll = useCallback(
    (visibleRange: { start: number; end: number }, metadata?: Record<string, unknown>) =>
      capture('scroll', 'viewport', { visibleRange, ...metadata }),
    [capture]
  );

  const captureHover = useCallback(
    (target: string, durationMs: number, metadata?: Record<string, unknown>) =>
      capture('hover', target, { durationMs, ...metadata }),
    [capture]
  );

  const getElementProps = useCallback(() => ({
    onClick: (e: React.MouseEvent) => {
      const target = (e.target as HTMLElement).tagName?.toLowerCase() || 'unknown';
      captureClick(target, { x: e.clientX, y: e.clientY });
    },
    onFocus: () => {
      focusStartRef.current = Date.now();
      capture('focus', componentId);
    },
    onBlur: () => {
      if (focusStartRef.current) {
        const duration = Date.now() - focusStartRef.current;
        capture('blur', componentId, { focusDurationMs: duration });
        focusStartRef.current = null;
      }
    },
  }), [capture, captureClick, componentId]);

  return {
    capture,
    captureClick,
    captureSelect,
    captureFilter,
    captureSort,
    captureNavigate,
    captureSearch,
    captureExpand,
    captureScroll,
    captureHover,
    getElementProps,
  };
}

// ============================================================================
// SUBSCRIPTION HOOK
// ============================================================================

/**
 * Subscribe to capture events (useful for debugging or real-time displays).
 */
export function useCaptureSubscription(
  onEvent: (event: InteractionEvent) => void,
  deps: unknown[] = []
): void {
  useEffect(() => {
    return captureService.subscribe(onEvent);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/**
 * Get capture statistics.
 */
export function useCaptureStats() {
  return useMemo(() => ({
    eventStats: captureService.getEventStats(),
    frequentComponents: captureService.getFrequentComponents(),
    recentEvents: captureService.getRecentEvents(30),
  }), []);
}

