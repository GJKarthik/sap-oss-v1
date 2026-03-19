/**
 * Adaptive UI Architecture — Layer 1: Interaction Capture Types
 * 
 * Captures user interactions to build behavioral models.
 * Privacy-first: all capture is local, explicit consent for sync.
 */

// ============================================================================
// INTERACTION EVENTS — Raw user actions
// ============================================================================

export type InteractionType =
  | 'click'
  | 'hover'
  | 'scroll'
  | 'focus'
  | 'blur'
  | 'input'
  | 'select'
  | 'drag'
  | 'drop'
  | 'resize'
  | 'sort'
  | 'filter'
  | 'expand'
  | 'collapse'
  | 'navigate'
  | 'search'
  | 'export'
  | 'undo'
  | 'redo';

export interface InteractionEvent {
  /** Unique event ID */
  id: string;
  /** Event type */
  type: InteractionType;
  /** Timestamp */
  timestamp: Date;
  /** Target element identifier (semantic, not DOM) */
  target: string;
  /** Component type (filter, table, chart, etc.) */
  componentType: string;
  /** Component instance ID */
  componentId: string;
  /** Additional metadata */
  metadata: Record<string, unknown>;
  /** Duration for timed events (hover, focus) */
  durationMs?: number;
  /** Session ID for grouping */
  sessionId: string;
}

// ============================================================================
// DERIVED EVENTS — Higher-level patterns
// ============================================================================

export interface NavigationPattern {
  /** Sequence of component visits */
  path: string[];
  /** Time spent on each */
  dwellTimes: number[];
  /** Final destination */
  destination: string;
  /** Whether user achieved their goal */
  successful: boolean;
}

export interface FilterPattern {
  /** Filter field used */
  field: string;
  /** Values selected */
  values: unknown[];
  /** Order of selection */
  selectionOrder: number[];
  /** Time to complete filter selection */
  completionTimeMs: number;
  /** Whether filter was cleared/reset */
  wasReset: boolean;
}

export interface TableInteractionPattern {
  /** Columns viewed (scrolled into view) */
  columnsViewed: string[];
  /** Column order preferences */
  columnReorders: Array<{ from: number; to: number }>;
  /** Sort preferences */
  sortPreferences: Array<{ column: string; direction: 'asc' | 'desc' }>;
  /** Row expansion patterns */
  expandedRows: number[];
  /** Pagination preferences */
  pageSizePreference: number;
}

// ============================================================================
// CAPTURE CONFIGURATION — Privacy controls
// ============================================================================

export interface CaptureConfig {
  /** Whether capture is enabled */
  enabled: boolean;
  /** Events to capture */
  capturedEvents: InteractionType[];
  /** Components to exclude (e.g., password fields) */
  excludedComponents: string[];
  /** Maximum events to store locally */
  maxLocalEvents: number;
  /** Retention period in days */
  retentionDays: number;
  /** Whether to sync to backend */
  syncEnabled: boolean;
  /** Sync consent timestamp */
  syncConsentAt?: Date;
  /** Anonymization level */
  anonymizationLevel: 'none' | 'partial' | 'full';
}

export const DEFAULT_CAPTURE_CONFIG: CaptureConfig = {
  enabled: true,
  capturedEvents: [
    'click', 'select', 'filter', 'sort', 'search', 
    'expand', 'collapse', 'navigate', 'export'
  ],
  excludedComponents: ['password', 'secret', 'api-key'],
  maxLocalEvents: 10000,
  retentionDays: 30,
  syncEnabled: false,
  anonymizationLevel: 'partial',
};

// ============================================================================
// CAPTURE SERVICE INTERFACE
// ============================================================================

export interface CaptureService {
  /** Capture a single interaction */
  capture(event: Omit<InteractionEvent, 'id' | 'timestamp' | 'sessionId'>): void;
  /** Get captured events for a component */
  getEventsForComponent(componentId: string, limit?: number): InteractionEvent[];
  /** Get captured events by type */
  getEventsByType(type: InteractionType, limit?: number): InteractionEvent[];
  /** Clear all captured events */
  clear(): void;
  /** Export captured events (for debugging/analysis) */
  export(): InteractionEvent[];
  /** Update capture configuration */
  configure(config: Partial<CaptureConfig>): void;
  /** Get current configuration */
  getConfig(): CaptureConfig;
}

