/**
 * Adaptive UI Architecture — Data-Based Adaptation Rules
 * 
 * Rules that adapt UI based on data characteristics.
 */

import type { AdaptationRule } from '../types';

// ============================================================================
// DATA VOLUME RULES
// ============================================================================

export const largeDatasetRule: AdaptationRule = {
  id: 'data-large-dataset',
  name: 'Large Dataset Optimization',
  priority: 85,
  condition: (ctx) => ctx.data.rowCount > 1000,
  apply: (current) => ({
    ...current,
    content: {
      ...current.content,
      pageSize: Math.min(current.content?.pageSize || 25, 50), // Cap at 50
    },
    layout: {
      ...current.layout,
      density: 'compact', // Fit more data
    },
    interaction: {
      ...current.interaction,
      enableDragDrop: false, // Performance
    },
  }),
  userOverridable: true,
};

export const sparseDatasetRule: AdaptationRule = {
  id: 'data-sparse-dataset',
  name: 'Sparse Dataset Display',
  priority: 85,
  condition: (ctx) => ctx.data.rowCount < 10 && ctx.data.rowCount > 0,
  apply: (current) => ({
    ...current,
    content: {
      ...current.content,
      pageSize: ctx => ctx.data.rowCount, // Show all
    },
    layout: {
      ...current.layout,
      density: 'spacious', // More breathing room
    },
  }),
  userOverridable: true,
};

export const emptyDatasetRule: AdaptationRule = {
  id: 'data-empty-dataset',
  name: 'Empty State Display',
  priority: 90,
  condition: (ctx) => ctx.data.rowCount === 0,
  apply: (current) => ({
    ...current,
    feedback: {
      ...current.feedback,
      showOnboardingHints: true,
      showFeatureDiscovery: true,
    },
    predictive: {
      ...current.predictive,
      workflowShortcuts: [
        {
          name: 'Add First Item',
          description: 'Get started by adding data',
          action: () => {},
        },
        {
          name: 'Import Data',
          description: 'Import from file or system',
          action: () => {},
        },
      ],
    },
  }),
  userOverridable: true,
};

// ============================================================================
// DATA QUALITY RULES
// ============================================================================

export const staleDataRule: AdaptationRule = {
  id: 'data-stale',
  name: 'Stale Data Warning',
  priority: 80,
  condition: (ctx) => ctx.data.dataAge === 'stale' || ctx.data.dataAge === 'historical',
  apply: (current) => ({
    ...current,
    feedback: {
      ...current.feedback,
      showProgressIndicators: true, // Show refresh indicator
    },
    predictive: {
      ...current.predictive,
      predictedActions: [
        ...(current.predictive?.predictedActions || []),
        { action: 'refresh', probability: 0.9, shortcut: 'Ctrl+R' },
      ],
    },
  }),
  userOverridable: true,
};

export const realtimeDataRule: AdaptationRule = {
  id: 'data-realtime',
  name: 'Realtime Data Display',
  priority: 80,
  condition: (ctx) => ctx.data.updateFrequency === 'realtime',
  apply: (current) => ({
    ...current,
    interaction: {
      ...current.interaction,
      animationScale: 0.5, // Subtle animations for updates
    },
    feedback: {
      ...current.feedback,
      autoSaveIntervalMs: 0, // Disable auto-save, data is live
      showProgressIndicators: true,
    },
  }),
  userOverridable: true,
};

export const sensitiveDataRule: AdaptationRule = {
  id: 'data-sensitive',
  name: 'Sensitive Data Protection',
  priority: 95, // High priority - security
  condition: (ctx) => ctx.data.sensitivityLevel === 'confidential' || 
                      ctx.data.sensitivityLevel === 'restricted',
  apply: (current) => ({
    ...current,
    feedback: {
      ...current.feedback,
      confirmationLevel: 'all', // Confirm all actions
      autoSaveIntervalMs: 60000, // Less frequent auto-save
    },
    interaction: {
      ...current.interaction,
      enableDragDrop: false, // Prevent accidental moves
    },
    predictive: {
      ...current.predictive,
      prefetchData: [], // Don't prefetch sensitive data
    },
  }),
  userOverridable: false, // Security rule
};

// ============================================================================
// EXPORT
// ============================================================================

export const dataRules: AdaptationRule[] = [
  largeDatasetRule,
  sparseDatasetRule,
  emptyDatasetRule,
  staleDataRule,
  realtimeDataRule,
  sensitiveDataRule,
];

