/**
 * Adaptive UI Architecture — Default Adaptation Rules
 * 
 * These rules encode the "intelligence" of the system.
 * Each rule checks a condition and applies an adaptation.
 */

import type { AdaptationRule, AdaptationDecision } from '../types';
import type { AdaptiveContext } from '../../context/types';
import type { UserModel } from '../../modeling/types';

// ============================================================================
// DEVICE-BASED RULES
// ============================================================================

export const mobileLayoutRule: AdaptationRule = {
  id: 'device-mobile-layout',
  name: 'Mobile Device Layout',
  priority: 100,
  condition: (ctx) => ctx.device.type === 'mobile',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'comfortable',
      gridColumns: 1,
      spacingScale: 1.5,
      sidebarState: 'hidden',
    },
    interaction: {
      ...current.interaction,
      touchTargetScale: 1.5,
      enableDragDrop: false,
      hoverDelayMs: 0, // No hover on mobile
    },
  }),
  userOverridable: true,
};

export const reducedMotionRule: AdaptationRule = {
  id: 'a11y-reduced-motion',
  name: 'Reduced Motion Accessibility',
  priority: 200, // High priority - accessibility
  condition: (ctx) => ctx.device.prefersReducedMotion,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      animationScale: 0,
    },
  }),
  userOverridable: false, // Accessibility, don't override
};

export const slowConnectionRule: AdaptationRule = {
  id: 'perf-slow-connection',
  name: 'Slow Connection Optimization',
  priority: 90,
  condition: (ctx) => ['slow-2g', '2g', '3g'].includes(ctx.device.connectionType),
  apply: (current) => ({
    ...current,
    content: {
      ...current.content,
      pageSize: 10, // Smaller pages
      preloadData: [], // Don't preload
    },
    interaction: {
      ...current.interaction,
      animationScale: 0, // Disable animations
    },
    predictive: {
      ...current.predictive,
      prefetchData: [], // Don't prefetch
    },
  }),
  userOverridable: true,
};

// ============================================================================
// USER MODEL-BASED RULES
// ============================================================================

export const expertUserRule: AdaptationRule = {
  id: 'user-expert',
  name: 'Expert User Density',
  priority: 80,
  condition: (_, model) => model?.expertise?.level === 'expert',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'compact',
      spacingScale: 0.75,
    },
    feedback: {
      ...current.feedback,
      showOnboardingHints: false,
      hintComplexity: 'advanced',
      confirmationLevel: 'none',
    },
    interaction: {
      ...current.interaction,
      enableKeyboardShortcuts: true,
      showShortcutHints: true,
    },
  }),
  userOverridable: true,
};

export const noviceUserRule: AdaptationRule = {
  id: 'user-novice',
  name: 'Novice User Guidance',
  priority: 80,
  condition: (_, model) => model?.expertise?.level === 'novice' || !model,
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'spacious',
      spacingScale: 1.25,
    },
    feedback: {
      ...current.feedback,
      showOnboardingHints: true,
      hintComplexity: 'basic',
      showFeatureDiscovery: true,
      confirmationLevel: 'all',
    },
  }),
  userOverridable: true,
};

export const keyboardUserRule: AdaptationRule = {
  id: 'a11y-keyboard-user',
  name: 'Keyboard Navigation User',
  priority: 150,
  condition: (_, model) => model?.accessibility?.keyboardOnly === true,
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      enableKeyboardShortcuts: true,
      showShortcutHints: true,
      tooltipDelayMs: 0, // Instant tooltips
    },
    feedback: {
      ...current.feedback,
      showProgressIndicators: true,
    },
  }),
  userOverridable: false,
};

// ============================================================================
// TASK-BASED RULES
// ============================================================================

export const analyzeTaskRule: AdaptationRule = {
  id: 'task-analyze',
  name: 'Analysis Mode',
  priority: 70,
  condition: (ctx) => ctx.task.mode === 'analyze',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'compact',
      autoExpandPanels: ['filters', 'details'],
    },
    content: {
      ...current.content,
      pageSize: 50, // More data visible
    },
  }),
  userOverridable: true,
};

export const executeTaskRule: AdaptationRule = {
  id: 'task-execute',
  name: 'Execution Mode',
  priority: 70,
  condition: (ctx) => ctx.task.mode === 'execute',
  apply: (current) => ({
    ...current,
    layout: {
      density: current.layout?.density || 'comfortable',
      ...current.layout,
      autoCollapsePanels: ['filters', 'history'],
      autoExpandPanels: ['actions'],
    },
    feedback: {
      ...current.feedback,
      confirmationLevel: 'destructive',
      autoSaveIntervalMs: 5000, // Frequent auto-save
    },
  }),
  userOverridable: true,
};

export const criticalUrgencyRule: AdaptationRule = {
  id: 'task-critical',
  name: 'Critical Urgency Mode',
  priority: 150,
  condition: (ctx) => ctx.task.urgency === 'critical',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'compact',
    },
    feedback: {
      ...current.feedback,
      confirmationLevel: 'none', // Fast action
      showProgressIndicators: true,
    },
    predictive: {
      ...current.predictive,
      workflowShortcuts: [
        { name: 'Quick Action', description: 'Execute immediately', action: () => {} },
      ],
    },
  }),
  userOverridable: true,
};

// ============================================================================
// EXPORT ALL RULES
// ============================================================================

export const defaultRules: AdaptationRule[] = [
  // Highest priority: Accessibility
  reducedMotionRule,
  keyboardUserRule,
  
  // High priority: Device
  mobileLayoutRule,
  slowConnectionRule,
  
  // Medium priority: Task
  criticalUrgencyRule,
  analyzeTaskRule,
  executeTaskRule,
  
  // Lower priority: User preferences
  expertUserRule,
  noviceUserRule,
];

