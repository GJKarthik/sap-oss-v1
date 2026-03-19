/**
 * Adaptive UI Architecture — Layer 2: User Modeling Types
 * 
 * Builds and maintains user profiles from captured interactions.
 * This is WHERE we learn "what does this user prefer?"
 */

// ============================================================================
// PREFERENCE MODELS — What the user likes
// ============================================================================

export interface LayoutPreferences {
  /** Preferred information density */
  density: 'compact' | 'comfortable' | 'spacious';
  /** Confidence in this preference (0-1) */
  densityConfidence: number;
  /** Preferred sidebar position */
  sidebarPosition: 'left' | 'right' | 'hidden';
  /** Preferred panel arrangements */
  panelOrder: string[];
  /** Collapsed panels by default */
  defaultCollapsed: string[];
}

export interface TablePreferences {
  /** Preferred page size */
  pageSize: number;
  /** Column visibility preferences by table type */
  columnVisibility: Record<string, string[]>;
  /** Column order preferences by table type */
  columnOrder: Record<string, string[]>;
  /** Default sort preferences by table type */
  defaultSort: Record<string, { column: string; direction: 'asc' | 'desc' }>;
  /** Row height preference */
  rowHeight: 'compact' | 'normal' | 'expanded';
}

export interface FilterPreferences {
  /** Frequently used filters by context */
  frequentFilters: Record<string, Array<{ field: string; value: unknown }>>;
  /** Saved filter presets */
  savedPresets: Array<{ name: string; filters: Record<string, unknown> }>;
  /** Preferred filter panel position */
  filterPanelPosition: 'top' | 'side' | 'modal';
  /** Auto-apply filters or require explicit action */
  autoApply: boolean;
}

export interface VisualizationPreferences {
  /** Preferred chart type by data type */
  chartTypeByData: Record<string, 'bar' | 'line' | 'pie' | 'scatter' | 'table'>;
  /** Color scheme preference */
  colorScheme: string;
  /** Show data labels */
  showDataLabels: boolean;
  /** Animation preference */
  enableAnimations: boolean;
}

export interface NavigationPreferences {
  /** Frequently visited sections */
  frequentSections: Array<{ path: string; visitCount: number; lastVisit: Date }>;
  /** Preferred starting view */
  defaultView: string;
  /** Keyboard shortcut usage */
  usesKeyboardShortcuts: boolean;
  /** Breadcrumb vs back button preference */
  navigationStyle: 'breadcrumb' | 'back' | 'mixed';
}

// ============================================================================
// BEHAVIORAL MODELS — How the user works
// ============================================================================

export interface ExpertiseModel {
  /** Overall expertise level (inferred) */
  level: 'novice' | 'intermediate' | 'expert';
  /** Confidence in this assessment */
  confidence: number;
  /** Domain-specific expertise */
  domainExpertise: Record<string, 'novice' | 'intermediate' | 'expert'>;
  /** Feature familiarity scores */
  featureFamiliarity: Record<string, number>;
  /** Learning velocity (how fast they adopt new features) */
  learningVelocity: 'slow' | 'moderate' | 'fast';
}

export interface WorkPatternModel {
  /** Typical work hours */
  activeHours: { start: number; end: number };
  /** Peak productivity times */
  peakHours: number[];
  /** Session duration patterns */
  typicalSessionDuration: number;
  /** Task switching frequency */
  taskSwitchingFrequency: 'low' | 'moderate' | 'high';
  /** Batch vs real-time work preference */
  workStyle: 'batch' | 'realtime' | 'mixed';
}

export interface AccessibilityNeeds {
  /** Screen reader usage detected */
  usesScreenReader: boolean;
  /** Keyboard-only navigation detected */
  keyboardOnly: boolean;
  /** Larger touch targets needed */
  needsLargerTargets: boolean;
  /** Higher contrast needed */
  needsHighContrast: boolean;
  /** Reduced motion needed */
  needsReducedMotion: boolean;
  /** Text size preference */
  textSizeMultiplier: number;
}

// ============================================================================
// COMPLETE USER MODEL
// ============================================================================

export interface UserModel {
  /** User identifier */
  userId: string;
  /** Model version (for migrations) */
  modelVersion: number;
  /** Last updated timestamp */
  lastUpdated: Date;
  /** Total interactions observed */
  interactionCount: number;
  
  // Preference models
  layout: LayoutPreferences;
  tables: TablePreferences;
  filters: FilterPreferences;
  visualizations: VisualizationPreferences;
  navigation: NavigationPreferences;
  
  // Behavioral models
  expertise: ExpertiseModel;
  workPatterns: WorkPatternModel;
  accessibility: AccessibilityNeeds;
  
  /** Model confidence (overall) */
  confidence: number;
  /** Days of data used to build model */
  dataSpanDays: number;
}

// ============================================================================
// MODEL SERVICE INTERFACE
// ============================================================================

export interface ModelingService {
  /** Get current user model */
  getModel(userId: string): UserModel | null;
  /** Update model from new interactions */
  updateModel(userId: string, events: import('./types').InteractionEvent[]): void;
  /** Reset model to defaults */
  resetModel(userId: string): void;
  /** Export model (for debugging/portability) */
  exportModel(userId: string): UserModel | null;
  /** Import model (for portability) */
  importModel(model: UserModel): void;
  /** Get model confidence */
  getConfidence(userId: string): number;
}

