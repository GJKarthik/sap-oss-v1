/**
 * Adaptive UI Architecture — Temporal Adaptation Rules
 * 
 * Rules that adapt UI based on time context.
 */

import type { AdaptationRule } from '../types';

// ============================================================================
// TIME OF DAY RULES
// ============================================================================

export const eveningModeRule: AdaptationRule = {
  id: 'temporal-evening',
  name: 'Evening Mode',
  priority: 60,
  condition: (ctx) => ctx.temporal.timeOfDay === 'evening' || ctx.temporal.timeOfDay === 'night',
  apply: (current, ctx) => ({
    ...current,
    layout: {
      ...current.layout,
      // If device prefers dark mode, we're already good
      // Otherwise suggest comfort settings for late work
      density: ctx.device.prefersColorScheme === 'dark' ? current.layout?.density : 'comfortable',
    },
    feedback: {
      ...current.feedback,
      // Fewer distractions in evening
      showFeatureDiscovery: false,
    },
  }),
  userOverridable: true,
};

export const morningDashboardRule: AdaptationRule = {
  id: 'temporal-morning-dashboard',
  name: 'Morning Dashboard Focus',
  priority: 60,
  condition: (ctx) => ctx.temporal.timeOfDay === 'morning' && ctx.task.mode === 'monitor',
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      autoExpandPanels: ['summary', 'alerts', 'kpis'],
      autoCollapsePanels: ['details', 'history'],
    },
    predictive: {
      ...current.predictive,
      recommendedView: 'dashboard',
      predictedActions: [
        { action: 'view-summary', probability: 0.9 },
        { action: 'check-alerts', probability: 0.8 },
      ],
    },
  }),
  userOverridable: true,
};

// ============================================================================
// SESSION RULES
// ============================================================================

export const longSessionRule: AdaptationRule = {
  id: 'temporal-long-session',
  name: 'Long Session Comfort',
  priority: 55,
  condition: (ctx) => ctx.temporal.sessionDurationMinutes > 60,
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      // Slightly more spacing for extended sessions
      spacingScale: Math.min((current.layout?.spacingScale || 1) * 1.1, 1.5),
    },
    feedback: {
      ...current.feedback,
      // More frequent auto-save for long sessions
      autoSaveIntervalMs: Math.min(current.feedback?.autoSaveIntervalMs || 30000, 15000),
    },
    predictive: {
      ...current.predictive,
      workflowShortcuts: [
        ...(current.predictive?.workflowShortcuts || []),
        {
          name: 'Save Progress',
          description: 'Save your work',
          action: () => {},
        },
      ],
    },
  }),
  userOverridable: true,
};

export const newSessionRule: AdaptationRule = {
  id: 'temporal-new-session',
  name: 'New Session Welcome',
  priority: 50,
  condition: (ctx) => ctx.temporal.sessionDurationMinutes < 2,
  apply: (current, ctx, model) => ({
    ...current,
    predictive: {
      ...current.predictive,
      // Suggest recently used features
      recommendedView: model?.navigation?.defaultView || 'home',
      predictedActions: model?.navigation?.frequentSections?.slice(0, 3).map(s => ({
        action: `navigate-${s.path}`,
        probability: 0.7,
      })) || [],
    },
  }),
  userOverridable: true,
};

// ============================================================================
// BUSINESS PERIOD RULES
// ============================================================================

export const endOfDayRule: AdaptationRule = {
  id: 'temporal-end-of-day',
  name: 'End of Day Mode',
  priority: 65,
  condition: (ctx) => ctx.temporal.businessPeriod === 'end-of-day',
  apply: (current) => ({
    ...current,
    feedback: {
      ...current.feedback,
      showProgressIndicators: true,
      autoSaveIntervalMs: 10000, // More frequent saves
    },
    predictive: {
      ...current.predictive,
      workflowShortcuts: [
        {
          name: 'Save & Close',
          description: 'Save all work and prepare to leave',
          action: () => {},
        },
        {
          name: 'Schedule for Tomorrow',
          description: 'Defer remaining tasks',
          action: () => {},
        },
      ],
    },
  }),
  userOverridable: true,
};

export const weekendRule: AdaptationRule = {
  id: 'temporal-weekend',
  name: 'Weekend Mode',
  priority: 55,
  condition: (ctx) => {
    const day = new Date().getDay();
    return day === 0 || day === 6; // Sunday or Saturday
  },
  apply: (current) => ({
    ...current,
    layout: {
      ...current.layout,
      density: 'comfortable', // More relaxed
    },
    feedback: {
      ...current.feedback,
      confirmationLevel: 'all', // Be more careful on weekends
    },
  }),
  userOverridable: true,
};

// ============================================================================
// EXPORT
// ============================================================================

export const temporalRules: AdaptationRule[] = [
  eveningModeRule,
  morningDashboardRule,
  longSessionRule,
  newSessionRule,
  endOfDayRule,
  weekendRule,
];

