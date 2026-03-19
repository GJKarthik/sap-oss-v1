/**
 * Adaptive UI Architecture — Adaptation Coordinator
 * 
 * Connects all layers together:
 * Context + User Model → Adaptation Engine → UI Updates
 * 
 * This is the "brain" that makes the UI actually adapt in real-time.
 */

import { contextProvider } from '../context/context-provider';
import { modelingService } from '../modeling/modeling-service';
import { adaptationEngine } from './engine';
import type { AdaptationDecision } from './types';
import type { AdaptiveContext } from '../context/types';
import type { UserModel } from '../modeling/types';

// ============================================================================
// TYPES
// ============================================================================

export interface CoordinatorConfig {
  /** Debounce time for context changes (ms) */
  debounceMs: number;
  /** Whether to auto-start on creation */
  autoStart: boolean;
  /** Minimum confidence to apply adaptation */
  minConfidence: number;
  /** Whether to generate CSS variables */
  generateCssVariables: boolean;
  /** CSS variable prefix */
  cssVariablePrefix: string;
}

const DEFAULT_CONFIG: CoordinatorConfig = {
  debounceMs: 100,
  autoStart: true,
  minConfidence: 0.3,
  generateCssVariables: true,
  cssVariablePrefix: '--adaptive',
};

export type AdaptationListener = (decision: AdaptationDecision) => void;

// ============================================================================
// COORDINATOR IMPLEMENTATION
// ============================================================================

export class AdaptationCoordinator {
  private config: CoordinatorConfig;
  private currentDecision: AdaptationDecision | null = null;
  private listeners: Set<AdaptationListener> = new Set();
  private debounceTimeout: ReturnType<typeof setTimeout> | null = null;
  private unsubscribeContext: (() => void) | null = null;
  private unsubscribeModel: (() => void) | null = null;
  private currentUserId: string | null = null;
  private isRunning = false;
  
  constructor(config: Partial<CoordinatorConfig> = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    
    if (this.config.autoStart) {
      this.start();
    }
  }
  
  /** Start coordinating adaptations */
  start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    
    // Subscribe to context changes
    this.unsubscribeContext = contextProvider.subscribe((ctx) => {
      this.onContextChange(ctx);
    });
    
    // Initial adaptation
    this.triggerAdaptation();
  }
  
  /** Stop coordinating */
  stop(): void {
    if (!this.isRunning) return;
    this.isRunning = false;
    
    if (this.unsubscribeContext) {
      this.unsubscribeContext();
      this.unsubscribeContext = null;
    }
    
    if (this.unsubscribeModel) {
      this.unsubscribeModel();
      this.unsubscribeModel = null;
    }
    
    if (this.debounceTimeout) {
      clearTimeout(this.debounceTimeout);
      this.debounceTimeout = null;
    }
  }
  
  private onContextChange(ctx: AdaptiveContext): void {
    // If user changed, update model subscription
    if (ctx.user.userId !== this.currentUserId) {
      this.currentUserId = ctx.user.userId;
      
      if (this.unsubscribeModel) {
        this.unsubscribeModel();
      }
      
      // Subscribe to model updates for this user
      this.unsubscribeModel = modelingService.subscribe(ctx.user.userId, () => {
        this.triggerAdaptation();
      });
    }
    
    this.triggerAdaptation();
  }
  
  private triggerAdaptation(): void {
    // Debounce rapid changes
    if (this.debounceTimeout) {
      clearTimeout(this.debounceTimeout);
    }
    
    this.debounceTimeout = setTimeout(() => {
      this.computeAndApply();
    }, this.config.debounceMs);
  }
  
  private computeAndApply(): void {
    const ctx = contextProvider.getContext();
    const model = modelingService.getModel(ctx.user.userId);
    
    // Generate adaptation decision
    const decision = adaptationEngine.decide(ctx, model);
    
    // Only apply if confidence meets threshold
    if (decision.confidence < this.config.minConfidence && model) {
      // Use defaults with low confidence
      decision.explanations['low-confidence'] = 'Using defaults due to low model confidence';
    }
    
    this.currentDecision = decision;
    
    // Generate CSS variables
    if (this.config.generateCssVariables) {
      this.applyCssVariables(decision);
    }
    
    // Notify listeners
    this.notifyListeners(decision);
  }
  
  private applyCssVariables(decision: AdaptationDecision): void {
    if (typeof document === 'undefined') return;

    const root = document.documentElement;
    const prefix = this.config.cssVariablePrefix;

    // Layout variables
    const spacing = decision.layout.spacingScale * 8;
    root.style.setProperty(`${prefix}-spacing-unit`, `${spacing}px`);
    root.style.setProperty(`${prefix}-spacing-xs`, `${spacing * 0.5}px`);
    root.style.setProperty(`${prefix}-spacing-sm`, `${spacing}px`);
    root.style.setProperty(`${prefix}-spacing-md`, `${spacing * 2}px`);
    root.style.setProperty(`${prefix}-spacing-lg`, `${spacing * 3}px`);
    root.style.setProperty(`${prefix}-spacing-xl`, `${spacing * 4}px`);

    // Grid columns
    root.style.setProperty(`${prefix}-grid-columns`, `${decision.layout.gridColumns}`);

    // Density-based sizing
    const densityScale = {
      compact: 0.85,
      comfortable: 1,
      spacious: 1.2,
    }[decision.layout.density];
    root.style.setProperty(`${prefix}-density-scale`, `${densityScale}`);

    // Touch targets
    const touchScale = decision.interaction.touchTargetScale;
    root.style.setProperty(`${prefix}-touch-target-min`, `${44 * touchScale}px`);

    // Animation duration
    const animScale = decision.interaction.animationScale;
    root.style.setProperty(`${prefix}-animation-duration`, `${150 * animScale}ms`);
    root.style.setProperty(`${prefix}-transition-duration`, `${200 * animScale}ms`);

    // Tooltip/hover delays
    root.style.setProperty(`${prefix}-hover-delay`, `${decision.interaction.hoverDelayMs}ms`);
    root.style.setProperty(`${prefix}-tooltip-delay`, `${decision.interaction.tooltipDelayMs}ms`);

    // Sidebar state
    root.style.setProperty(
      `${prefix}-sidebar-width`,
      decision.layout.sidebarState === 'expanded' ? '280px' :
      decision.layout.sidebarState === 'collapsed' ? '64px' : '0px'
    );
  }

  private notifyListeners(decision: AdaptationDecision): void {
    for (const listener of this.listeners) {
      try {
        listener(decision);
      } catch (e) {
        console.error('[AdaptationCoordinator] Listener error:', e);
      }
    }
  }

  // ============================================================================
  // PUBLIC API
  // ============================================================================

  /** Subscribe to adaptation decisions */
  subscribe(listener: AdaptationListener): () => void {
    this.listeners.add(listener);

    // Immediately call with current decision if available
    if (this.currentDecision) {
      listener(this.currentDecision);
    }

    return () => this.listeners.delete(listener);
  }

  /** Get current adaptation decision */
  getCurrentDecision(): AdaptationDecision | null {
    return this.currentDecision;
  }

  /** Force a re-adaptation */
  forceAdapt(): void {
    this.computeAndApply();
  }

  /** Set a user override */
  setOverride(key: string, value: unknown): void {
    adaptationEngine.setOverride(key, value);
    this.forceAdapt();
  }

  /** Clear a user override */
  clearOverride(key: string): void {
    adaptationEngine.clearOverride(key);
    this.forceAdapt();
  }

  /** Clear all user overrides */
  clearAllOverrides(): void {
    const overrides = adaptationEngine.getOverrides();
    for (const key of Object.keys(overrides)) {
      adaptationEngine.clearOverride(key);
    }
    this.forceAdapt();
  }

  /** Check if coordinator is running */
  isActive(): boolean {
    return this.isRunning;
  }

  /** Get CSS variables as object (for SSR) */
  getCssVariablesObject(): Record<string, string> {
    if (!this.currentDecision) return {};

    const decision = this.currentDecision;
    const prefix = this.config.cssVariablePrefix;
    const spacing = decision.layout.spacingScale * 8;
    const densityScale = {
      compact: 0.85,
      comfortable: 1,
      spacious: 1.2,
    }[decision.layout.density];

    return {
      [`${prefix}-spacing-unit`]: `${spacing}px`,
      [`${prefix}-spacing-xs`]: `${spacing * 0.5}px`,
      [`${prefix}-spacing-sm`]: `${spacing}px`,
      [`${prefix}-spacing-md`]: `${spacing * 2}px`,
      [`${prefix}-spacing-lg`]: `${spacing * 3}px`,
      [`${prefix}-spacing-xl`]: `${spacing * 4}px`,
      [`${prefix}-grid-columns`]: `${decision.layout.gridColumns}`,
      [`${prefix}-density-scale`]: `${densityScale}`,
      [`${prefix}-touch-target-min`]: `${44 * decision.interaction.touchTargetScale}px`,
      [`${prefix}-animation-duration`]: `${150 * decision.interaction.animationScale}ms`,
      [`${prefix}-transition-duration`]: `${200 * decision.interaction.animationScale}ms`,
      [`${prefix}-hover-delay`]: `${decision.interaction.hoverDelayMs}ms`,
      [`${prefix}-tooltip-delay`]: `${decision.interaction.tooltipDelayMs}ms`,
      [`${prefix}-sidebar-width`]: decision.layout.sidebarState === 'expanded' ? '280px' :
        decision.layout.sidebarState === 'collapsed' ? '64px' : '0px',
    };
  }
}

// Singleton instance
export const adaptationCoordinator = new AdaptationCoordinator();

