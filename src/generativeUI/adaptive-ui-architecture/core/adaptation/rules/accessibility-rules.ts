/**
 * Adaptive UI Architecture — Accessibility Adaptation Rules
 * 
 * Rules that ensure WCAG compliance and adapt to accessibility needs.
 * These rules are NON-NEGOTIABLE and have highest priority.
 */

import type { AdaptationRule } from '../types';

// ============================================================================
// MOTION & ANIMATION RULES
// ============================================================================

export const reducedMotionRule: AdaptationRule = {
  id: 'a11y-reduced-motion',
  name: 'Reduced Motion',
  priority: 300, // Highest priority
  condition: (ctx) => ctx.device.prefersReducedMotion,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      animationScale: 0,
      hoverDelayMs: 0, // No delayed hover effects
    },
  }),
  userOverridable: false, // Accessibility - never override
};

// ============================================================================
// CONTRAST & COLOR RULES
// ============================================================================

export const highContrastRule: AdaptationRule = {
  id: 'a11y-high-contrast',
  name: 'High Contrast Mode',
  priority: 300,
  condition: (ctx) => ctx.device.prefersContrast === 'more',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      // Increase spacing for clearer boundaries
      spacingScale: Math.max(current.layout?.spacingScale || 1, 1.25),
    },
  }),
  userOverridable: false,
};

// ============================================================================
// INPUT METHOD RULES
// ============================================================================

export const keyboardOnlyRule: AdaptationRule = {
  id: 'a11y-keyboard-only',
  name: 'Keyboard Navigation',
  priority: 250,
  condition: (_, model) => model?.accessibility?.keyboardOnly === true,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      enableKeyboardShortcuts: true,
      showShortcutHints: true,
      tooltipDelayMs: 0, // Instant tooltips for keyboard users
      hoverDelayMs: 0, // No hover delays
    },
    feedback: {
      ...current.feedback,
      showProgressIndicators: true, // Always show progress for non-visual feedback
    },
  }),
  userOverridable: false,
};

export const touchDeviceRule: AdaptationRule = {
  id: 'a11y-touch-device',
  name: 'Touch Target Sizing',
  priority: 200,
  condition: (ctx) => ctx.device.hasTouch && ctx.device.pointerPrecision === 'coarse',
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      touchTargetScale: Math.max(current.interaction?.touchTargetScale || 1, 1.25),
      enableDragDrop: false, // Drag is hard on touch
      hoverDelayMs: 0, // No hover on touch
    },
    layout: {
      ...current.layout,
      // Ensure minimum spacing for touch
      spacingScale: Math.max(current.layout?.spacingScale || 1, 1.25),
    },
  }),
  userOverridable: true,
};

export const largerTargetsRule: AdaptationRule = {
  id: 'a11y-larger-targets',
  name: 'Larger Touch Targets',
  priority: 220,
  condition: (_, model) => model?.accessibility?.needsLargerTargets === true,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      touchTargetScale: Math.max(current.interaction?.touchTargetScale || 1, 1.5),
    },
    layout: {
      ...current.layout,
      density: 'spacious',
      spacingScale: 1.5,
    },
  }),
  userOverridable: false,
};

// ============================================================================
// SCREEN READER RULES
// ============================================================================

export const screenReaderRule: AdaptationRule = {
  id: 'a11y-screen-reader',
  name: 'Screen Reader Optimization',
  priority: 280,
  condition: (_, model) => model?.accessibility?.usesScreenReader === true,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      animationScale: 0, // No animations
      enableKeyboardShortcuts: true,
    },
    feedback: {
      ...current.feedback,
      showProgressIndicators: true,
      confirmationLevel: 'all', // Announce all actions
    },
    content: {
      ...current.content,
      pageSize: Math.min(current.content?.pageSize || 25, 25), // Manageable chunks
    },
  }),
  userOverridable: false,
};

// ============================================================================
// TEXT SIZE RULES
// ============================================================================

export const largerTextRule: AdaptationRule = {
  id: 'a11y-larger-text',
  name: 'Larger Text Preference',
  priority: 200,
  condition: (_, model) => (model?.accessibility?.textSizeMultiplier || 1) > 1.2,
  apply: (current, _, model) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'spacious', // More room for larger text
      gridColumns: Math.min(current.layout?.gridColumns || 12, 8), // Fewer columns
    },
  }),
  userOverridable: true,
};

// ============================================================================
// EXPORT
// ============================================================================

export const accessibilityRules: AdaptationRule[] = [
  // Highest priority - system preferences
  reducedMotionRule,
  highContrastRule,
  
  // High priority - detected needs
  screenReaderRule,
  keyboardOnlyRule,
  largerTargetsRule,
  
  // Medium priority - device-based
  touchDeviceRule,
  largerTextRule,
];

