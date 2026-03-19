/**
 * Adaptive UI Architecture — Layer 1: Capture Service
 * 
 * Records user interactions for behavioral modeling.
 * Privacy-first: all data stays local unless explicitly synced.
 */

import type {
  InteractionEvent,
  InteractionType,
  CaptureConfig,
  CaptureService,
  NavigationPattern,
  FilterPattern,
  TableInteractionPattern,
} from './types';
import { DEFAULT_CAPTURE_CONFIG } from './types';
import { contextProvider } from '../context/context-provider';

// ============================================================================
// STORAGE KEYS
// ============================================================================

const EVENTS_STORAGE_KEY = 'adaptive-ui-events';
const CONFIG_STORAGE_KEY = 'adaptive-ui-capture-config';
const PATTERNS_STORAGE_KEY = 'adaptive-ui-patterns';

// ============================================================================
// CAPTURE SERVICE IMPLEMENTATION
// ============================================================================

export class CaptureServiceImpl implements CaptureService {
  private events: InteractionEvent[] = [];
  private config: CaptureConfig;
  private sessionId: string;
  private listeners: Set<(event: InteractionEvent) => void> = new Set();
  
  // Pattern accumulators
  private navigationPath: string[] = [];
  private navigationTimes: number[] = [];
  private lastNavigationTime: number = Date.now();

  constructor() {
    this.sessionId = contextProvider.getSessionId();
    this.config = this.loadConfig();
    this.loadEvents();
    this.setupCleanup();
  }

  private loadConfig(): CaptureConfig {
    if (typeof localStorage === 'undefined') return DEFAULT_CAPTURE_CONFIG;
    
    try {
      const stored = localStorage.getItem(CONFIG_STORAGE_KEY);
      if (stored) {
        return { ...DEFAULT_CAPTURE_CONFIG, ...JSON.parse(stored) };
      }
    } catch {
      // Ignore parse errors
    }
    return DEFAULT_CAPTURE_CONFIG;
  }

  private saveConfig(): void {
    if (typeof localStorage === 'undefined') return;
    
    try {
      localStorage.setItem(CONFIG_STORAGE_KEY, JSON.stringify(this.config));
    } catch {
      // Ignore storage errors
    }
  }

  private loadEvents(): void {
    if (typeof localStorage === 'undefined') return;
    
    try {
      const stored = localStorage.getItem(EVENTS_STORAGE_KEY);
      if (stored) {
        this.events = JSON.parse(stored);
        // Reconstitute dates
        this.events.forEach(e => {
          e.timestamp = new Date(e.timestamp);
        });
      }
    } catch {
      this.events = [];
    }
  }

  private saveEvents(): void {
    if (typeof localStorage === 'undefined') return;
    
    try {
      // Keep only the most recent events
      const toStore = this.events.slice(-this.config.maxLocalEvents);
      localStorage.setItem(EVENTS_STORAGE_KEY, JSON.stringify(toStore));
    } catch {
      // Handle quota exceeded by trimming older events
      this.events = this.events.slice(-Math.floor(this.config.maxLocalEvents / 2));
      try {
        localStorage.setItem(EVENTS_STORAGE_KEY, JSON.stringify(this.events));
      } catch {
        // Give up
      }
    }
  }

  private setupCleanup(): void {
    // Clean up old events on initialization
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - this.config.retentionDays);
    
    this.events = this.events.filter(e => e.timestamp >= cutoffDate);
    this.saveEvents();
  }

  private generateEventId(): string {
    return `evt-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  }

  private shouldCapture(type: InteractionType, target: string): boolean {
    if (!this.config.enabled) return false;
    if (!this.config.capturedEvents.includes(type)) return false;
    if (this.config.excludedComponents.some(exc => target.includes(exc))) return false;
    return true;
  }

  private anonymize(event: InteractionEvent): InteractionEvent {
    if (this.config.anonymizationLevel === 'none') return event;
    
    const anonymized = { ...event };
    
    if (this.config.anonymizationLevel === 'full') {
      // Remove all potentially identifying metadata
      anonymized.metadata = {};
    } else {
      // Partial: remove specific sensitive fields
      const sensitiveKeys = ['email', 'name', 'userId', 'phone', 'address'];
      anonymized.metadata = Object.fromEntries(
        Object.entries(event.metadata).filter(
          ([key]) => !sensitiveKeys.some(sk => key.toLowerCase().includes(sk))
        )
      );
    }
    
    return anonymized;
  }

  // ============================================================================
  // PUBLIC API
  // ============================================================================

  capture(event: Omit<InteractionEvent, 'id' | 'timestamp' | 'sessionId'>): void {
    if (!this.shouldCapture(event.type, event.target)) return;

    const fullEvent: InteractionEvent = {
      ...event,
      id: this.generateEventId(),
      timestamp: new Date(),
      sessionId: this.sessionId,
    };

    const anonymizedEvent = this.anonymize(fullEvent);
    this.events.push(anonymizedEvent);
    
    // Track navigation patterns
    if (event.type === 'navigate') {
      this.trackNavigation(event.target);
    }

    // Notify listeners
    for (const listener of this.listeners) {
      try {
        listener(anonymizedEvent);
      } catch (e) {
        console.error('[CaptureService] Listener error:', e);
      }
    }

    // Batch save (debounced in real impl, immediate here for simplicity)
    this.saveEvents();
  }

  private trackNavigation(target: string): void {
    const now = Date.now();
    const dwellTime = now - this.lastNavigationTime;

    if (this.navigationPath.length > 0) {
      this.navigationTimes.push(dwellTime);
    }

    this.navigationPath.push(target);
    this.lastNavigationTime = now;

    // Keep last 20 navigation points
    if (this.navigationPath.length > 20) {
      this.navigationPath.shift();
      this.navigationTimes.shift();
    }
  }

  getEventsForComponent(componentId: string, limit = 100): InteractionEvent[] {
    return this.events
      .filter(e => e.componentId === componentId)
      .slice(-limit);
  }

  getEventsByType(type: InteractionType, limit = 100): InteractionEvent[] {
    return this.events
      .filter(e => e.type === type)
      .slice(-limit);
  }

  getEventsInTimeRange(startTime: Date, endTime: Date): InteractionEvent[] {
    return this.events.filter(
      e => e.timestamp >= startTime && e.timestamp <= endTime
    );
  }

  getRecentEvents(minutes: number): InteractionEvent[] {
    const cutoff = new Date(Date.now() - minutes * 60 * 1000);
    return this.events.filter(e => e.timestamp >= cutoff);
  }

  clear(): void {
    this.events = [];
    this.navigationPath = [];
    this.navigationTimes = [];
    if (typeof localStorage !== 'undefined') {
      localStorage.removeItem(EVENTS_STORAGE_KEY);
    }
  }

  export(): InteractionEvent[] {
    return [...this.events];
  }

  configure(config: Partial<CaptureConfig>): void {
    this.config = { ...this.config, ...config };
    this.saveConfig();
  }

  getConfig(): CaptureConfig {
    return { ...this.config };
  }

  /** Subscribe to new capture events */
  subscribe(listener: (event: InteractionEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // ============================================================================
  // PATTERN EXTRACTION
  // ============================================================================

  getNavigationPattern(): NavigationPattern {
    return {
      path: [...this.navigationPath],
      dwellTimes: [...this.navigationTimes],
      destination: this.navigationPath[this.navigationPath.length - 1] || '',
      successful: true, // Would need task completion tracking
    };
  }

  getFilterPatterns(componentId: string): FilterPattern[] {
    const filterEvents = this.events.filter(
      e => e.componentId === componentId && e.type === 'filter'
    );

    // Group by session to find patterns
    const patterns: FilterPattern[] = [];
    let currentPattern: Partial<FilterPattern> | null = null;
    let selectionOrder = 0;
    let startTime = 0;

    for (const event of filterEvents) {
      const field = event.metadata['field'] as string;
      const value = event.metadata['value'];

      if (!currentPattern || currentPattern.field !== field) {
        if (currentPattern) {
          patterns.push(currentPattern as FilterPattern);
        }
        currentPattern = {
          field,
          values: [value],
          selectionOrder: [selectionOrder++],
          completionTimeMs: 0,
          wasReset: false,
        };
        startTime = event.timestamp.getTime();
      } else {
        currentPattern.values = [...(currentPattern.values || []), value];
        currentPattern.selectionOrder = [
          ...(currentPattern.selectionOrder || []),
          selectionOrder++,
        ];
        currentPattern.completionTimeMs = event.timestamp.getTime() - startTime;
      }

      if (event.metadata['reset']) {
        currentPattern.wasReset = true;
      }
    }

    if (currentPattern) {
      patterns.push(currentPattern as FilterPattern);
    }

    return patterns;
  }

  getTableInteractionPattern(componentId: string): TableInteractionPattern {
    const tableEvents = this.events.filter(
      e => e.componentId === componentId &&
           ['sort', 'scroll', 'expand', 'resize'].includes(e.type)
    );

    const columnsViewed: string[] = [];
    const columnReorders: Array<{ from: number; to: number }> = [];
    const sortPreferences: Array<{ column: string; direction: 'asc' | 'desc' }> = [];
    const expandedRows: number[] = [];
    let pageSizePreference = 25;

    for (const event of tableEvents) {
      if (event.type === 'sort' && event.metadata['column']) {
        sortPreferences.push({
          column: event.metadata['column'] as string,
          direction: (event.metadata['direction'] as 'asc' | 'desc') || 'asc',
        });
      }

      if (event.type === 'expand' && typeof event.metadata['rowIndex'] === 'number') {
        expandedRows.push(event.metadata['rowIndex'] as number);
      }

      if (event.type === 'scroll' && event.metadata['visibleColumns']) {
        const cols = event.metadata['visibleColumns'] as string[];
        for (const col of cols) {
          if (!columnsViewed.includes(col)) {
            columnsViewed.push(col);
          }
        }
      }

      if (event.metadata['pageSize']) {
        pageSizePreference = event.metadata['pageSize'] as number;
      }
    }

    return {
      columnsViewed,
      columnReorders,
      sortPreferences,
      expandedRows,
      pageSizePreference,
    };
  }

  /** Get event count by type for statistics */
  getEventStats(): Record<InteractionType, number> {
    const stats: Partial<Record<InteractionType, number>> = {};

    for (const event of this.events) {
      stats[event.type] = (stats[event.type] || 0) + 1;
    }

    return stats as Record<InteractionType, number>;
  }

  /** Get most frequently interacted components */
  getFrequentComponents(limit = 10): Array<{ componentId: string; count: number }> {
    const counts: Record<string, number> = {};

    for (const event of this.events) {
      counts[event.componentId] = (counts[event.componentId] || 0) + 1;
    }

    return Object.entries(counts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([componentId, count]) => ({ componentId, count }));
  }
}

// Singleton instance
export const captureService = new CaptureServiceImpl();
