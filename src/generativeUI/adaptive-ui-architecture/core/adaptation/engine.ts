/**
 * Adaptive UI Architecture — Layer 3: Adaptation Engine
 * 
 * The brain of the system. Takes context + user model → adaptation decisions.
 */

import type { 
  AdaptationEngine, 
  AdaptationRule, 
  AdaptationDecision,
  LayoutAdaptation,
  ContentAdaptation,
  InteractionAdaptation,
  FeedbackAdaptation,
  PredictiveAdaptation,
} from './types';
import type { AdaptiveContext } from '../context/types';
import type { UserModel } from '../modeling/types';
import { defaultRules } from './rules/default-rules';

// ============================================================================
// DEFAULT ADAPTATIONS
// ============================================================================

function getDefaultLayout(): LayoutAdaptation {
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

function getDefaultContent(): ContentAdaptation {
  return {
    visibleColumns: [],
    columnOrder: [],
    pageSize: 25,
    preAppliedFilters: {},
    suggestedFilters: [],
    preloadData: [],
  };
}

function getDefaultInteraction(): InteractionAdaptation {
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

function getDefaultFeedback(): FeedbackAdaptation {
  return {
    showOnboardingHints: true,
    hintComplexity: 'intermediate',
    showFeatureDiscovery: true,
    confirmationLevel: 'destructive',
    autoSaveIntervalMs: 30000,
    showProgressIndicators: true,
  };
}

function getDefaultPredictive(): PredictiveAdaptation {
  return {
    predictedActions: [],
    recommendedView: 'default',
    prefetchData: [],
    workflowShortcuts: [],
  };
}

// ============================================================================
// ENGINE IMPLEMENTATION
// ============================================================================

export class AdaptationEngineImpl implements AdaptationEngine {
  private rules: AdaptationRule[] = [];
  private overrides: Record<string, unknown> = {};

  constructor(rules: AdaptationRule[] = defaultRules) {
    this.rules = [...rules].sort((a, b) => b.priority - a.priority);
  }

  decide(context: AdaptiveContext, model: UserModel | null): AdaptationDecision {
    // Start with defaults
    let decision: Partial<AdaptationDecision> = {
      id: `decision-${Date.now()}`,
      timestamp: new Date(),
      context,
      userModelId: model?.userId || 'anonymous',
      layout: getDefaultLayout(),
      content: getDefaultContent(),
      interaction: getDefaultInteraction(),
      feedback: getDefaultFeedback(),
      predictive: getDefaultPredictive(),
      confidence: model ? model.confidence : 0.5,
      explanations: {},
      userOverrides: { ...this.overrides },
    };

    // Apply rules in priority order
    for (const rule of this.rules) {
      if (rule.condition(context, model)) {
        const before = JSON.stringify(decision);
        decision = rule.apply(decision, context, model);
        
        // Track what changed
        if (JSON.stringify(decision) !== before) {
          decision.explanations = {
            ...decision.explanations,
            [rule.id]: rule.name,
          };
        }
      }
    }

    // Apply user-specific preferences from model
    if (model) {
      decision = this.applyUserPreferences(decision, model);
    }

    // Apply explicit overrides last
    decision = this.applyOverrides(decision);

    return decision as AdaptationDecision;
  }

  private applyUserPreferences(
    decision: Partial<AdaptationDecision>, 
    model: UserModel
  ): Partial<AdaptationDecision> {
    // Apply layout preferences
    if (model.layout) {
      decision.layout = {
        ...decision.layout!,
        density: model.layout.densityConfidence > 0.7 ? model.layout.density : decision.layout!.density,
        sidebarState: model.layout.sidebarPosition === 'hidden' ? 'hidden' : decision.layout!.sidebarState,
        panelOrder: model.layout.panelOrder.length > 0 ? model.layout.panelOrder : decision.layout!.panelOrder,
      };
    }

    // Apply table preferences
    if (model.tables) {
      decision.content = {
        ...decision.content!,
        pageSize: model.tables.pageSize || decision.content!.pageSize,
      };
    }

    // Apply filter preferences
    if (model.filters?.frequentFilters) {
      const contextKey = decision.context?.task.mode || 'default';
      const frequent = model.filters.frequentFilters[contextKey] || [];
      decision.content = {
        ...decision.content!,
        suggestedFilters: frequent.map(f => ({
          field: f.field,
          value: f.value,
          reason: 'Frequently used',
        })),
      };
    }

    return decision;
  }

  private applyOverrides(decision: Partial<AdaptationDecision>): Partial<AdaptationDecision> {
    // Apply each override to the appropriate section
    for (const [key, value] of Object.entries(this.overrides)) {
      const [section, prop] = key.split('.');
      if (section && prop && decision[section as keyof AdaptationDecision]) {
        (decision[section as keyof AdaptationDecision] as Record<string, unknown>)[prop] = value;
      }
    }
    return decision;
  }

  registerRule(rule: AdaptationRule): void {
    this.rules.push(rule);
    this.rules.sort((a, b) => b.priority - a.priority);
  }

  unregisterRule(ruleId: string): void {
    this.rules = this.rules.filter(r => r.id !== ruleId);
  }

  getRules(): AdaptationRule[] {
    return [...this.rules];
  }

  setOverride(key: string, value: unknown): void {
    this.overrides[key] = value;
  }

  clearOverride(key: string): void {
    delete this.overrides[key];
  }

  getOverrides(): Record<string, unknown> {
    return { ...this.overrides };
  }
}

// Singleton instance
export const adaptationEngine = new AdaptationEngineImpl();

