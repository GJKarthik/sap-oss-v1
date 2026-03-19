/**
 * Adaptive UI Architecture — Layer 3: Adaptation Engine Types
 * 
 * The decision-making layer. Takes context + user model → adaptation decisions.
 * This is WHERE intelligence happens.
 */

import type { AdaptiveContext } from '../context/types';
import type { UserModel } from '../modeling/types';

// ============================================================================
// ADAPTATION DECISIONS — What to change
// ============================================================================

export interface LayoutAdaptation {
  /** Information density to apply */
  density: 'compact' | 'comfortable' | 'spacious';
  /** Grid column count */
  gridColumns?: number;
  /** Spacing scale (multiplier of base 8px) */
  spacingScale?: number;
  /** Sidebar state */
  sidebarState?: 'expanded' | 'collapsed' | 'hidden';
  /** Panel order */
  panelOrder?: string[];
  /** Panels to auto-expand */
  autoExpandPanels?: string[];
  /** Panels to auto-collapse */
  autoCollapsePanels?: string[];
}

export interface ContentAdaptation {
  /** Columns to show (for tables) */
  visibleColumns?: string[];
  /** Column order */
  columnOrder?: string[];
  /** Default sort */
  defaultSort?: { column: string; direction: 'asc' | 'desc' };
  /** Page size */
  pageSize?: number;
  /** Pre-applied filters */
  preAppliedFilters?: Record<string, unknown>;
  /** Suggested filters (shown but not applied) */
  suggestedFilters?: Array<{ field: string; value: unknown; reason: string }>;
  /** Data to preload */
  preloadData?: string[];
}

export interface InteractionAdaptation {
  /** Touch target size multiplier */
  touchTargetScale?: number;
  /** Enable keyboard shortcuts */
  enableKeyboardShortcuts?: boolean;
  /** Show shortcut hints */
  showShortcutHints?: boolean;
  /** Enable drag and drop */
  enableDragDrop?: boolean;
  /** Hover delay (ms) */
  hoverDelayMs?: number;
  /** Tooltip delay (ms) */
  tooltipDelayMs?: number;
  /** Animation duration multiplier (0 = disabled) */
  animationScale?: number;
}

export interface FeedbackAdaptation {
  /** Show onboarding hints */
  showOnboardingHints?: boolean;
  /** Hint complexity level */
  hintComplexity?: 'basic' | 'intermediate' | 'advanced';
  /** Show feature discovery prompts */
  showFeatureDiscovery?: boolean;
  /** Confirmation level for actions */
  confirmationLevel?: 'none' | 'destructive' | 'all';
  /** Auto-save frequency */
  autoSaveIntervalMs?: number;
  /** Show progress indicators */
  showProgressIndicators?: boolean;
}

export interface PredictiveAdaptation {
  /** Predicted next actions */
  predictedActions?: Array<{
    action: string;
    probability: number;
    shortcut?: string;
  }>;
  /** Recommended view for current context */
  recommendedView?: string;
  /** Data to prefetch based on prediction */
  prefetchData?: string[];
  /** Suggested workflow shortcuts */
  workflowShortcuts?: Array<{
    name: string;
    description: string;
    action: () => void;
  }>;
}

// ============================================================================
// COMPLETE ADAPTATION — Full decision set
// ============================================================================

export interface AdaptationDecision {
  /** Decision ID (for tracking) */
  id: string;
  /** Timestamp */
  timestamp: Date;
  /** Input context */
  context: AdaptiveContext;
  /** User model used */
  userModelId: string;
  
  // Adaptation decisions
  layout: LayoutAdaptation;
  content: ContentAdaptation;
  interaction: InteractionAdaptation;
  feedback: FeedbackAdaptation;
  predictive: PredictiveAdaptation;
  
  /** Overall confidence in this decision */
  confidence: number;
  /** Explanation for key decisions (for transparency) */
  explanations: Record<string, string>;
  /** User overrides to apply */
  userOverrides: Record<string, unknown>;
}

// ============================================================================
// ADAPTATION RULES — How decisions are made
// ============================================================================

export interface AdaptationRule {
  /** Rule identifier */
  id: string;
  /** Human-readable name */
  name: string;
  /** Priority (higher = applied first) */
  priority: number;
  /** Condition to check */
  condition: (context: AdaptiveContext, model: UserModel | null) => boolean;
  /** Adaptation to apply if condition is true */
  apply: (
    current: Partial<AdaptationDecision>,
    context: AdaptiveContext,
    model: UserModel | null
  ) => Partial<AdaptationDecision>;
  /** Whether rule can be overridden by user */
  userOverridable: boolean;
}

// ============================================================================
// ENGINE INTERFACE
// ============================================================================

export interface AdaptationEngine {
  /** Generate adaptation decision */
  decide(context: AdaptiveContext, model: UserModel | null): AdaptationDecision;
  /** Register custom rule */
  registerRule(rule: AdaptationRule): void;
  /** Unregister rule */
  unregisterRule(ruleId: string): void;
  /** Get all registered rules */
  getRules(): AdaptationRule[];
  /** Apply user override */
  setOverride(key: string, value: unknown): void;
  /** Clear user override */
  clearOverride(key: string): void;
  /** Get all overrides */
  getOverrides(): Record<string, unknown>;
}

