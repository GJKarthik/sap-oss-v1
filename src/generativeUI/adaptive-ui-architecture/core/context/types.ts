/**
 * Adaptive UI Architecture — Layer 0: Context Types
 * 
 * Context provides the environmental signals that inform adaptation.
 * These are INPUTS to the adaptation engine — they describe the situation,
 * not the user's preferences (that's Layer 2).
 */

// ============================================================================
// USER CONTEXT — WHO is using the system
// ============================================================================

export interface UserRole {
  /** Primary role identifier (e.g., "procurement_manager", "analyst") */
  id: string;
  /** Human-readable role name */
  name: string;
  /** Permission level affects UI complexity */
  permissionLevel: 'viewer' | 'editor' | 'admin' | 'superadmin';
  /** Domain expertise affects information density */
  expertiseLevel: 'novice' | 'intermediate' | 'expert';
}

export interface UserContext {
  /** User's unique identifier */
  userId: string;
  /** Current role (users may have multiple) */
  role: UserRole;
  /** Organization/tenant context */
  organization: string;
  /** Locale for formatting */
  locale: string;
  /** Timezone for time-based adaptation */
  timezone: string;
}

// ============================================================================
// TASK CONTEXT — WHAT the user is trying to do
// ============================================================================

export type TaskMode = 
  | 'explore'      // Browsing, discovering
  | 'analyze'      // Deep investigation
  | 'execute'      // Taking action
  | 'monitor'      // Passive observation
  | 'collaborate'  // Working with others
  | 'present';     // Showing to stakeholders

export interface TaskContext {
  /** Current task mode */
  mode: TaskMode;
  /** Specific task identifier (if known) */
  taskId?: string;
  /** Task urgency affects UI density and shortcuts */
  urgency: 'low' | 'normal' | 'high' | 'critical';
  /** Whether user is in a workflow or free-form */
  inWorkflow: boolean;
  /** Current step in workflow (if applicable) */
  workflowStep?: number;
  /** Total steps in workflow (if applicable) */
  workflowTotalSteps?: number;
}

// ============================================================================
// TEMPORAL CONTEXT — WHEN the user is working
// ============================================================================

export interface TemporalContext {
  /** Current timestamp */
  timestamp: Date;
  /** Time of day affects defaults (morning summary vs EOD report) */
  timeOfDay: 'morning' | 'afternoon' | 'evening' | 'night';
  /** Day type affects priorities */
  dayType: 'weekday' | 'weekend' | 'holiday';
  /** Business period (quarter end, fiscal year end, etc.) */
  businessPeriod?: 'quarter_end' | 'year_end' | 'budget_cycle' | 'normal';
  /** Session duration (fatigue detection) */
  sessionDurationMinutes: number;
}

// ============================================================================
// DEVICE CONTEXT — HOW the user is accessing
// ============================================================================

export interface DeviceContext {
  /** Device type affects layout and interactions */
  type: 'desktop' | 'tablet' | 'mobile';
  /** Screen size for responsive adaptation */
  screenWidth: number;
  screenHeight: number;
  /** Pixel density for image quality decisions */
  pixelRatio: number;
  /** Touch capability affects target sizes */
  hasTouch: boolean;
  /** Pointer precision (coarse = finger, fine = mouse) */
  pointerPrecision: 'coarse' | 'fine';
  /** Connection quality affects data loading strategies */
  connectionType: 'slow-2g' | '2g' | '3g' | '4g' | '5g' | 'wifi' | 'ethernet' | 'unknown';
  /** Reduced motion preference (accessibility) */
  prefersReducedMotion: boolean;
  /** Color scheme preference */
  prefersColorScheme: 'light' | 'dark' | 'no-preference';
  /** High contrast mode */
  prefersContrast: 'more' | 'less' | 'no-preference';
}

// ============================================================================
// DATA CONTEXT — WHAT data is being worked with
// ============================================================================

export interface DataContext {
  /** Data volume affects pagination and virtualization */
  rowCount: number;
  /** Column count affects layout decisions */
  columnCount: number;
  /** Data freshness (stale data should be highlighted) */
  dataAge: 'live' | 'recent' | 'stale' | 'historical';
  /** Data quality affects confidence displays */
  dataQuality: 'verified' | 'provisional' | 'estimated' | 'unknown';
  /** Data sensitivity affects masking and export options */
  sensitivityLevel: 'public' | 'internal' | 'confidential' | 'restricted';
  /** Whether data is filterable */
  hasFilters: boolean;
  /** Whether data is sortable */
  hasSorting: boolean;
  /** Data update frequency */
  updateFrequency: 'realtime' | 'frequent' | 'periodic' | 'static';
}

// ============================================================================
// COMBINED CONTEXT — Full environmental snapshot
// ============================================================================

export interface AdaptiveContext {
  user: UserContext;
  task: TaskContext;
  temporal: TemporalContext;
  device: DeviceContext;
  data: DataContext;
  /** Context generation timestamp */
  generatedAt: Date;
  /** Context confidence (how certain are we about these values) */
  confidence: number; // 0-1
}

