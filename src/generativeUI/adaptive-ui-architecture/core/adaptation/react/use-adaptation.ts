/**
 * Adaptive UI Architecture — React Adaptation Hooks
 * 
 * React hooks for consuming adaptation decisions.
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { adaptationCoordinator } from '../coordinator';
import type { AdaptationDecision, LayoutAdaptation, ContentAdaptation, InteractionAdaptation } from '../types';

// ============================================================================
// MAIN HOOK
// ============================================================================

/**
 * Subscribe to adaptation decisions.
 * 
 * @example
 * ```tsx
 * function MyComponent() {
 *   const { decision, layout, content, interaction } = useAdaptation();
 *   
 *   return (
 *     <div style={{ 
 *       gap: `${layout.spacingScale * 8}px`,
 *       gridTemplateColumns: `repeat(${layout.gridColumns}, 1fr)`
 *     }}>
 *       {content.suggestedFilters.map(f => (
 *         <FilterChip key={f.field} {...f} />
 *       ))}
 *     </div>
 *   );
 * }
 * ```
 */
export function useAdaptation(): {
  decision: AdaptationDecision | null;
  layout: LayoutAdaptation;
  content: ContentAdaptation;
  interaction: InteractionAdaptation;
  confidence: number;
  isReady: boolean;
} {
  const [decision, setDecision] = useState<AdaptationDecision | null>(
    adaptationCoordinator.getCurrentDecision()
  );
  
  useEffect(() => {
    return adaptationCoordinator.subscribe(setDecision);
  }, []);
  
  const defaults = useMemo(() => ({
    layout: {
      density: 'comfortable' as const,
      gridColumns: 12,
      spacingScale: 1,
      sidebarState: 'expanded' as const,
      panelOrder: [],
      autoExpandPanels: [],
      autoCollapsePanels: [],
    },
    content: {
      visibleColumns: [],
      columnOrder: [],
      pageSize: 25,
      preAppliedFilters: {},
      suggestedFilters: [],
      preloadData: [],
    },
    interaction: {
      touchTargetScale: 1,
      enableKeyboardShortcuts: false,
      showShortcutHints: false,
      enableDragDrop: true,
      hoverDelayMs: 200,
      tooltipDelayMs: 500,
      animationScale: 1,
    },
  }), []);
  
  return {
    decision,
    layout: decision?.layout || defaults.layout,
    content: decision?.content || defaults.content,
    interaction: decision?.interaction || defaults.interaction,
    confidence: decision?.confidence || 0,
    isReady: decision !== null,
  };
}

// ============================================================================
// LAYOUT HOOK
// ============================================================================

/**
 * Get just layout adaptations with CSS-ready values.
 */
export function useAdaptiveLayout() {
  const { layout, isReady } = useAdaptation();
  
  return useMemo(() => ({
    ...layout,
    isReady,
    // CSS-ready values
    spacing: layout.spacingScale * 8,
    spacingXs: layout.spacingScale * 4,
    spacingSm: layout.spacingScale * 8,
    spacingMd: layout.spacingScale * 16,
    spacingLg: layout.spacingScale * 24,
    spacingXl: layout.spacingScale * 32,
    densityClass: `density-${layout.density}`,
    gridStyle: {
      display: 'grid',
      gridTemplateColumns: `repeat(${layout.gridColumns}, 1fr)`,
      gap: `${layout.spacingScale * 8}px`,
    },
  }), [layout, isReady]);
}

// ============================================================================
// INTERACTION HOOK
// ============================================================================

/**
 * Get interaction adaptations with helper functions.
 */
export function useAdaptiveInteraction() {
  const { interaction, isReady } = useAdaptation();
  
  const animationStyle = useMemo(() => ({
    transition: interaction.animationScale > 0 
      ? `all ${interaction.animationScale * 200}ms ease` 
      : 'none',
  }), [interaction.animationScale]);
  
  const touchTargetStyle = useMemo(() => ({
    minWidth: `${44 * interaction.touchTargetScale}px`,
    minHeight: `${44 * interaction.touchTargetScale}px`,
  }), [interaction.touchTargetScale]);
  
  return {
    ...interaction,
    isReady,
    animationStyle,
    touchTargetStyle,
    shouldAnimate: interaction.animationScale > 0,
    shouldShowShortcuts: interaction.enableKeyboardShortcuts && interaction.showShortcutHints,
  };
}

// ============================================================================
// OVERRIDE HOOK
// ============================================================================

/**
 * Manage user overrides.
 */
export function useAdaptationOverrides() {
  const setOverride = useCallback((key: string, value: unknown) => {
    adaptationCoordinator.setOverride(key, value);
  }, []);
  
  const clearOverride = useCallback((key: string) => {
    adaptationCoordinator.clearOverride(key);
  }, []);
  
  const clearAll = useCallback(() => {
    adaptationCoordinator.clearAllOverrides();
  }, []);
  
  return { setOverride, clearOverride, clearAll };
}

