/**
 * Adaptive UI Architecture — Layer 0: Context Provider
 *
 * Gathers environmental context from various sources.
 * This is the FOUNDATION of adaptive UI — understanding the situation.
 */

import type {
  AdaptiveContext,
  UserContext,
  TaskContext,
  TemporalContext,
  DeviceContext,
  DataContext,
  TaskMode,
} from './types';

// ============================================================================
// STORAGE KEY
// ============================================================================

const CONTEXT_STORAGE_KEY = 'adaptive-ui-context';

// ============================================================================
// CONTEXT DETECTION FUNCTIONS
// ============================================================================

function detectDeviceContext(): DeviceContext {
  // Safe check for SSR
  if (typeof window === 'undefined') {
    return getDefaultDeviceContext();
  }

  const mediaQueries = {
    prefersReducedMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
    prefersColorScheme: window.matchMedia('(prefers-color-scheme: dark)').matches
      ? 'dark' as const
      : window.matchMedia('(prefers-color-scheme: light)').matches
        ? 'light' as const
        : 'no-preference' as const,
    prefersContrast: window.matchMedia('(prefers-contrast: more)').matches
      ? 'more' as const
      : window.matchMedia('(prefers-contrast: less)').matches
        ? 'less' as const
        : 'no-preference' as const,
  };

  const connection = (navigator as Navigator & { connection?: { effectiveType?: string } }).connection;
  const connectionType = connection?.effectiveType || 'unknown';

  return {
    type: window.innerWidth < 768 ? 'mobile' : window.innerWidth < 1024 ? 'tablet' : 'desktop',
    screenWidth: window.innerWidth,
    screenHeight: window.innerHeight,
    pixelRatio: window.devicePixelRatio || 1,
    hasTouch: 'ontouchstart' in window || navigator.maxTouchPoints > 0,
    pointerPrecision: window.matchMedia('(pointer: coarse)').matches ? 'coarse' : 'fine',
    connectionType: connectionType as DeviceContext['connectionType'],
    ...mediaQueries,
  };
}

function getDefaultDeviceContext(): DeviceContext {
  return {
    type: 'desktop',
    screenWidth: 1920,
    screenHeight: 1080,
    pixelRatio: 1,
    hasTouch: false,
    pointerPrecision: 'fine',
    connectionType: 'unknown',
    prefersReducedMotion: false,
    prefersColorScheme: 'no-preference',
    prefersContrast: 'no-preference',
  };
}

function detectTemporalContext(sessionStartTime: Date): TemporalContext {
  const now = new Date();
  const hour = now.getHours();
  const day = now.getDay();

  let timeOfDay: TemporalContext['timeOfDay'];
  if (hour >= 5 && hour < 12) timeOfDay = 'morning';
  else if (hour >= 12 && hour < 17) timeOfDay = 'afternoon';
  else if (hour >= 17 && hour < 21) timeOfDay = 'evening';
  else timeOfDay = 'night';

  const isWeekend = day === 0 || day === 6;

  return {
    timestamp: now,
    timeOfDay,
    dayType: isWeekend ? 'weekend' : 'weekday',
    businessPeriod: detectBusinessPeriod(now),
    sessionDurationMinutes: Math.floor((now.getTime() - sessionStartTime.getTime()) / 60000),
  };
}

function detectBusinessPeriod(date: Date): TemporalContext['businessPeriod'] {
  const month = date.getMonth();
  const dayOfMonth = date.getDate();

  if ([2, 5, 8, 11].includes(month) && dayOfMonth > 23) {
    return 'quarter_end';
  }
  if (month === 11 && dayOfMonth > 15) {
    return 'year_end';
  }
  return 'normal';
}

// ============================================================================
// CONTEXT PROVIDER CLASS
// ============================================================================

export class ContextProvider {
  private sessionStartTime: Date;
  private sessionId: string;
  private userContext: UserContext | null = null;
  private taskContext: TaskContext;
  private dataContext: DataContext;
  private listeners: Set<(ctx: AdaptiveContext) => void> = new Set();
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  private lastDeviceContext: DeviceContext | null = null;

  constructor() {
    this.sessionStartTime = new Date();
    this.sessionId = this.generateSessionId();
    this.taskContext = this.getDefaultTaskContext();
    this.dataContext = this.getDefaultDataContext();

    this.loadPersistedContext();
    this.setupListeners();
  }

  private generateSessionId(): string {
    return `session-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  }

  /** Get the current session ID */
  getSessionId(): string {
    return this.sessionId;
  }

  private getDefaultTaskContext(): TaskContext {
    return {
      mode: 'explore',
      urgency: 'normal',
      inWorkflow: false,
    };
  }

  private getDefaultDataContext(): DataContext {
    return {
      rowCount: 0,
      columnCount: 0,
      dataAge: 'live',
      dataQuality: 'verified',
      sensitivityLevel: 'internal',
      hasFilters: true,
      hasSorting: true,
      updateFrequency: 'periodic',
    };
  }

  private loadPersistedContext(): void {
    if (typeof localStorage === 'undefined') return;

    try {
      const stored = localStorage.getItem(CONTEXT_STORAGE_KEY);
      if (stored) {
        const { userContext, taskContext } = JSON.parse(stored);
        if (userContext) this.userContext = userContext;
        if (taskContext?.mode) this.taskContext.mode = taskContext.mode;
      }
    } catch {
      // Ignore parse errors
    }
  }

  private persistContext(): void {
    if (typeof localStorage === 'undefined') return;

    try {
      const toStore = {
        userContext: this.userContext,
        taskContext: { mode: this.taskContext.mode },
        savedAt: Date.now(),
      };
      localStorage.setItem(CONTEXT_STORAGE_KEY, JSON.stringify(toStore));
    } catch {
      // Ignore storage errors (quota exceeded, etc.)
    }
  }

  private setupListeners(): void {
    if (typeof window === 'undefined') return;

    // Debounced resize listener
    window.addEventListener('resize', () => this.debouncedNotify());

    // Media query listeners with change detection
    const mqDark = window.matchMedia('(prefers-color-scheme: dark)');
    const mqMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const mqContrast = window.matchMedia('(prefers-contrast: more)');

    mqDark.addEventListener('change', () => this.notifyListeners());
    mqMotion.addEventListener('change', () => this.notifyListeners());
    mqContrast.addEventListener('change', () => this.notifyListeners());

    // Visibility change (for session tracking)
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        this.notifyListeners();
      }
    });

    // Network change
    const connection = (navigator as Navigator & { connection?: EventTarget }).connection;
    if (connection) {
      connection.addEventListener('change', () => this.notifyListeners());
    }
  }

  private debouncedNotify(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.notifyListeners();
    }, 150);
  }

  /** Set user context (called on login/auth) */
  setUserContext(user: UserContext): void {
    this.userContext = user;
    this.persistContext();
    this.notifyListeners();
  }

  /** Clear user context (called on logout) */
  clearUserContext(): void {
    this.userContext = null;
    this.persistContext();
    this.notifyListeners();
  }

  /** Set current task mode */
  setTaskMode(mode: TaskMode): void {
    if (this.taskContext.mode !== mode) {
      this.taskContext = { ...this.taskContext, mode };
      this.persistContext();
      this.notifyListeners();
    }
  }

  /** Set task urgency */
  setTaskUrgency(urgency: TaskContext['urgency']): void {
    if (this.taskContext.urgency !== urgency) {
      this.taskContext = { ...this.taskContext, urgency };
      this.notifyListeners();
    }
  }

  /** Enter workflow mode */
  enterWorkflow(totalSteps: number): void {
    this.taskContext = {
      ...this.taskContext,
      inWorkflow: true,
      workflowStep: 1,
      workflowTotalSteps: totalSteps,
    };
    this.notifyListeners();
  }

  /** Advance workflow step */
  advanceWorkflow(): void {
    if (this.taskContext.inWorkflow && this.taskContext.workflowStep !== undefined) {
      this.taskContext = {
        ...this.taskContext,
        workflowStep: this.taskContext.workflowStep + 1,
      };
      this.notifyListeners();
    }
  }

  /** Exit workflow mode */
  exitWorkflow(): void {
    this.taskContext = {
      ...this.taskContext,
      inWorkflow: false,
      workflowStep: undefined,
      workflowTotalSteps: undefined,
    };
    this.notifyListeners();
  }

  /** Set data context for current view */
  setDataContext(data: Partial<DataContext>): void {
    this.dataContext = { ...this.dataContext, ...data };
    this.notifyListeners();
  }

  /** Get current full context */
  getContext(): AdaptiveContext {
    const device = detectDeviceContext();
    this.lastDeviceContext = device;

    return {
      user: this.userContext || this.getAnonymousUserContext(),
      task: this.taskContext,
      temporal: detectTemporalContext(this.sessionStartTime),
      device,
      data: this.dataContext,
      generatedAt: new Date(),
      confidence: this.userContext ? 0.9 : 0.5,
    };
  }

  /** Get last known device context (without re-detecting) */
  getLastDeviceContext(): DeviceContext {
    return this.lastDeviceContext || detectDeviceContext();
  }

  private getAnonymousUserContext(): UserContext {
    const locale = typeof navigator !== 'undefined' ? navigator.language : 'en-US';
    const timezone = typeof Intl !== 'undefined'
      ? Intl.DateTimeFormat().resolvedOptions().timeZone
      : 'UTC';

    return {
      userId: 'anonymous',
      role: { id: 'viewer', name: 'Viewer', permissionLevel: 'viewer', expertiseLevel: 'novice' },
      organization: 'unknown',
      locale,
      timezone,
    };
  }

  /** Subscribe to context changes */
  subscribe(listener: (ctx: AdaptiveContext) => void): () => void {
    this.listeners.add(listener);
    // Immediately call with current context
    listener(this.getContext());
    return () => this.listeners.delete(listener);
  }

  private notifyListeners(): void {
    const ctx = this.getContext();
    for (const listener of this.listeners) {
      try {
        listener(ctx);
      } catch (e) {
        console.error('[ContextProvider] Listener error:', e);
      }
    }
  }

  /** Reset session (for testing) */
  resetSession(): void {
    this.sessionStartTime = new Date();
    this.sessionId = this.generateSessionId();
    this.taskContext = this.getDefaultTaskContext();
    this.dataContext = this.getDefaultDataContext();
    this.notifyListeners();
  }
}

// Singleton instance
export const contextProvider = new ContextProvider();

