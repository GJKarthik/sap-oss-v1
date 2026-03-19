/**
 * Adaptive UI Architecture — Layer 2: User Modeling Service
 * 
 * Builds and maintains user profiles from captured interactions.
 * This is WHERE learning happens — transforming raw events into preferences.
 */

import type {
  UserModel,
  ModelingService,
  LayoutPreferences,
  TablePreferences,
  FilterPreferences,
  VisualizationPreferences,
  NavigationPreferences,
  ExpertiseModel,
  WorkPatternModel,
  AccessibilityNeeds,
} from './types';
import type { InteractionEvent, InteractionType } from '../capture/types';

// ============================================================================
// STORAGE
// ============================================================================

const MODEL_STORAGE_KEY = 'adaptive-ui-user-model';
const MODEL_VERSION = 1;

// ============================================================================
// DEFAULT MODEL
// ============================================================================

function createDefaultModel(userId: string): UserModel {
  return {
    userId,
    modelVersion: MODEL_VERSION,
    lastUpdated: new Date(),
    interactionCount: 0,
    
    layout: {
      density: 'comfortable',
      densityConfidence: 0,
      sidebarPosition: 'left',
      panelOrder: [],
      defaultCollapsed: [],
    },
    
    tables: {
      pageSize: 25,
      columnVisibility: {},
      columnOrder: {},
      defaultSort: {},
      rowHeight: 'normal',
    },
    
    filters: {
      frequentFilters: {},
      savedPresets: [],
      filterPanelPosition: 'top',
      autoApply: true,
    },
    
    visualizations: {
      chartTypeByData: {},
      colorScheme: 'default',
      showDataLabels: true,
      enableAnimations: true,
    },
    
    navigation: {
      frequentSections: [],
      defaultView: '',
      usesKeyboardShortcuts: false,
      navigationStyle: 'mixed',
    },
    
    expertise: {
      level: 'novice',
      confidence: 0,
      domainExpertise: {},
      featureFamiliarity: {},
      learningVelocity: 'moderate',
    },
    
    workPatterns: {
      activeHours: { start: 9, end: 17 },
      peakHours: [10, 14],
      typicalSessionDuration: 30,
      taskSwitchingFrequency: 'moderate',
      workStyle: 'mixed',
    },
    
    accessibility: {
      usesScreenReader: false,
      keyboardOnly: false,
      needsLargerTargets: false,
      needsHighContrast: false,
      needsReducedMotion: false,
      textSizeMultiplier: 1,
    },
    
    confidence: 0,
    dataSpanDays: 0,
  };
}

// ============================================================================
// INFERENCE FUNCTIONS — The "Learning" Logic
// ============================================================================

/** Infer density preference from interaction patterns */
function inferDensityPreference(
  events: InteractionEvent[],
  current: LayoutPreferences
): LayoutPreferences {
  // Look for scroll patterns — frequent scrolling suggests too dense
  const scrollEvents = events.filter(e => e.type === 'scroll');
  const expandEvents = events.filter(e => e.type === 'expand');
  const collapseEvents = events.filter(e => e.type === 'collapse');
  
  // If user collapses more than expands, they prefer compact
  const collapseRatio = collapseEvents.length / Math.max(expandEvents.length, 1);
  
  let density = current.density;
  let confidence = current.densityConfidence;
  
  if (collapseRatio > 2 && events.length > 20) {
    density = 'compact';
    confidence = Math.min(confidence + 0.1, 0.9);
  } else if (expandEvents.length > collapseEvents.length * 2 && events.length > 20) {
    density = 'spacious';
    confidence = Math.min(confidence + 0.1, 0.9);
  }
  
  // Track collapsed panels
  const collapsedPanels = collapseEvents
    .map(e => e.target)
    .filter((v, i, a) => a.indexOf(v) === i);
  
  return {
    ...current,
    density,
    densityConfidence: confidence,
    defaultCollapsed: [...new Set([...current.defaultCollapsed, ...collapsedPanels])],
  };
}

/** Infer table preferences from interactions */
function inferTablePreferences(
  events: InteractionEvent[],
  current: TablePreferences
): TablePreferences {
  const tableEvents = events.filter(e => e.componentType === 'table');
  const sortEvents = tableEvents.filter(e => e.type === 'sort');
  
  // Track sort preferences
  const defaultSort = { ...current.defaultSort };
  for (const event of sortEvents) {
    const tableId = event.componentId;
    const column = event.metadata.column as string;
    const direction = (event.metadata.direction as 'asc' | 'desc') || 'asc';
    
    if (column) {
      defaultSort[tableId] = { column, direction };
    }
  }
  
  // Infer page size preference
  let pageSize = current.pageSize;
  const paginationEvents = tableEvents.filter(
    e => e.type === 'navigate' && e.metadata.pageSize
  );
  if (paginationEvents.length > 0) {
    const sizes = paginationEvents.map(e => e.metadata.pageSize as number);
    pageSize = Math.round(sizes.reduce((a, b) => a + b, 0) / sizes.length);
  }
  
  return {
    ...current,
    defaultSort,
    pageSize,
  };
}

/** Infer filter preferences from interactions */
function inferFilterPreferences(
  events: InteractionEvent[],
  current: FilterPreferences
): FilterPreferences {
  const filterEvents = events.filter(e => e.type === 'filter');

  // Track frequent filter combinations by context
  const frequentFilters = { ...current.frequentFilters };
  const filterCounts: Record<string, Record<string, number>> = {};

  for (const event of filterEvents) {
    const context = event.componentId || 'default';
    const field = event.metadata.field as string;
    const value = event.metadata.value;

    if (field && value !== undefined && value !== '') {
      if (!filterCounts[context]) filterCounts[context] = {};
      const key = `${field}:${JSON.stringify(value)}`;
      filterCounts[context][key] = (filterCounts[context][key] || 0) + 1;
    }
  }

  // Convert counts to frequent filters (used 3+ times)
  for (const [context, counts] of Object.entries(filterCounts)) {
    const frequent = Object.entries(counts)
      .filter(([, count]) => count >= 3)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([key]) => {
        const [field, valueJson] = key.split(':');
        return { field, value: JSON.parse(valueJson) };
      });

    if (frequent.length > 0) {
      frequentFilters[context] = frequent;
    }
  }

  return {
    ...current,
    frequentFilters,
  };
}

/** Infer navigation preferences from interactions */
function inferNavigationPreferences(
  events: InteractionEvent[],
  current: NavigationPreferences
): NavigationPreferences {
  const navEvents = events.filter(e => e.type === 'navigate');

  // Track section visit frequency
  const sectionCounts: Record<string, { count: number; lastVisit: Date }> = {};

  for (const event of navEvents) {
    const path = event.target;
    if (!sectionCounts[path]) {
      sectionCounts[path] = { count: 0, lastVisit: event.timestamp };
    }
    sectionCounts[path].count++;
    sectionCounts[path].lastVisit = event.timestamp;
  }

  const frequentSections = Object.entries(sectionCounts)
    .map(([path, data]) => ({
      path,
      visitCount: data.count,
      lastVisit: data.lastVisit,
    }))
    .sort((a, b) => b.visitCount - a.visitCount)
    .slice(0, 10);

  // Detect keyboard shortcut usage
  const keyboardEvents = events.filter(
    e => e.metadata.triggeredBy === 'keyboard' || e.metadata.shortcut
  );
  const usesKeyboardShortcuts = keyboardEvents.length > events.length * 0.1;

  // Determine default view (most visited)
  const defaultView = frequentSections.length > 0
    ? frequentSections[0].path
    : current.defaultView;

  return {
    ...current,
    frequentSections,
    usesKeyboardShortcuts,
    defaultView,
  };
}

/** Infer expertise level from interaction patterns */
function inferExpertise(
  events: InteractionEvent[],
  current: ExpertiseModel
): ExpertiseModel {
  // Indicators of expertise:
  // - Use of keyboard shortcuts
  // - Fast task completion
  // - Use of advanced features
  // - Less reliance on help/tooltips

  const keyboardUsage = events.filter(
    e => e.metadata.triggeredBy === 'keyboard' || e.metadata.shortcut
  ).length / Math.max(events.length, 1);

  const advancedFeatures = ['export', 'undo', 'redo', 'drag', 'drop'];
  const advancedUsage = events.filter(
    e => advancedFeatures.includes(e.type)
  ).length / Math.max(events.length, 1);

  // Calculate expertise score (0-1)
  const expertiseScore = (keyboardUsage * 0.4) + (advancedUsage * 0.6);

  let level: 'novice' | 'intermediate' | 'expert' = 'novice';
  if (expertiseScore > 0.3) level = 'expert';
  else if (expertiseScore > 0.1) level = 'intermediate';

  // Update feature familiarity
  const featureFamiliarity = { ...current.featureFamiliarity };
  for (const event of events) {
    const feature = event.componentType;
    featureFamiliarity[feature] = Math.min(
      (featureFamiliarity[feature] || 0) + 0.1,
      1
    );
  }

  // Confidence increases with more data
  const confidence = Math.min(events.length / 100, 0.95);

  return {
    ...current,
    level,
    confidence,
    featureFamiliarity,
  };
}

/** Infer work patterns from event timestamps */
function inferWorkPatterns(
  events: InteractionEvent[],
  current: WorkPatternModel
): WorkPatternModel {
  if (events.length < 10) return current;

  // Analyze event timestamps to find active hours
  const hourCounts: number[] = new Array(24).fill(0);

  for (const event of events) {
    const hour = new Date(event.timestamp).getHours();
    hourCounts[hour]++;
  }

  // Find peak hours (top 3)
  const peakHours = hourCounts
    .map((count, hour) => ({ hour, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 3)
    .map(h => h.hour)
    .sort((a, b) => a - b);

  // Find active hours range
  const activeHours = hourCounts
    .map((count, hour) => ({ hour, count }))
    .filter(h => h.count > 0);

  const start = activeHours.length > 0
    ? Math.min(...activeHours.map(h => h.hour))
    : current.activeHours.start;
  const end = activeHours.length > 0
    ? Math.max(...activeHours.map(h => h.hour))
    : current.activeHours.end;

  // Analyze session duration (approximate from event gaps)
  const timestamps = events.map(e => new Date(e.timestamp).getTime()).sort();
  const gaps: number[] = [];
  for (let i = 1; i < timestamps.length; i++) {
    const gap = timestamps[i] - timestamps[i - 1];
    // Consider gap > 30min as session break
    if (gap > 30 * 60 * 1000) {
      gaps.push(gap);
    }
  }

  // Task switching frequency (many different components in short time)
  const recentEvents = events.slice(-50);
  const uniqueComponents = new Set(recentEvents.map(e => e.componentId)).size;
  const switchFrequency = uniqueComponents / recentEvents.length;

  let taskSwitchingFrequency: 'low' | 'moderate' | 'high' = 'moderate';
  if (switchFrequency > 0.7) taskSwitchingFrequency = 'high';
  else if (switchFrequency < 0.3) taskSwitchingFrequency = 'low';

  return {
    ...current,
    activeHours: { start, end },
    peakHours,
    taskSwitchingFrequency,
  };
}

/** Infer accessibility needs from behavior */
function inferAccessibilityNeeds(
  events: InteractionEvent[],
  current: AccessibilityNeeds
): AccessibilityNeeds {
  // Detect keyboard-only usage (no click/hover events)
  const mouseEvents = events.filter(
    e => e.type === 'click' || e.type === 'hover'
  );
  const keyboardEvents = events.filter(
    e => e.metadata.triggeredBy === 'keyboard' || e.type === 'focus'
  );

  const keyboardOnly = events.length > 20 &&
    mouseEvents.length === 0 &&
    keyboardEvents.length > 0;

  // Detect need for larger targets (many near-miss clicks corrected)
  // This would require additional tracking in real impl

  // Reduced motion preference is detected from context, not behavior
  // But we can infer it from avoiding animated elements

  return {
    ...current,
    keyboardOnly,
  };
}

// ============================================================================
// MODELING SERVICE IMPLEMENTATION
// ============================================================================

export class ModelingServiceImpl implements ModelingService {
  private models: Map<string, UserModel> = new Map();
  private listeners: Map<string, Set<(model: UserModel) => void>> = new Map();

  constructor() {
    this.loadFromStorage();
  }

  private loadFromStorage(): void {
    if (typeof localStorage === 'undefined') return;

    try {
      const raw = localStorage.getItem(MODEL_STORAGE_KEY);
      if (raw) {
        const data = JSON.parse(raw);
        for (const [userId, model] of Object.entries(data)) {
          // Convert date strings back to Date objects
          const parsed = model as UserModel;
          parsed.lastUpdated = new Date(parsed.lastUpdated);
          if (parsed.navigation?.frequentSections) {
            for (const section of parsed.navigation.frequentSections) {
              section.lastVisit = new Date(section.lastVisit);
            }
          }
          this.models.set(userId, parsed);
        }
      }
    } catch (e) {
      console.error('[ModelingService] Failed to load models:', e);
    }
  }

  private saveToStorage(): void {
    if (typeof localStorage === 'undefined') return;

    try {
      const data: Record<string, UserModel> = {};
      for (const [userId, model] of this.models) {
        data[userId] = model;
      }
      localStorage.setItem(MODEL_STORAGE_KEY, JSON.stringify(data));
    } catch (e) {
      console.error('[ModelingService] Failed to save models:', e);
    }
  }

  private notifyListeners(userId: string, model: UserModel): void {
    const listeners = this.listeners.get(userId);
    if (listeners) {
      for (const listener of listeners) {
        try {
          listener(model);
        } catch (e) {
          console.error('[ModelingService] Listener error:', e);
        }
      }
    }
  }

  // ============================================================================
  // PUBLIC API
  // ============================================================================

  getModel(userId: string): UserModel | null {
    return this.models.get(userId) || null;
  }

  getOrCreateModel(userId: string): UserModel {
    let model = this.models.get(userId);
    if (!model) {
      model = createDefaultModel(userId);
      this.models.set(userId, model);
      this.saveToStorage();
    }
    return model;
  }

  updateModel(userId: string, events: InteractionEvent[]): void {
    if (events.length === 0) return;

    const model = this.getOrCreateModel(userId);

    // Apply all inference functions
    model.layout = inferDensityPreference(events, model.layout);
    model.tables = inferTablePreferences(events, model.tables);
    model.filters = inferFilterPreferences(events, model.filters);
    model.navigation = inferNavigationPreferences(events, model.navigation);
    model.expertise = inferExpertise(events, model.expertise);
    model.workPatterns = inferWorkPatterns(events, model.workPatterns);
    model.accessibility = inferAccessibilityNeeds(events, model.accessibility);

    // Update metadata
    model.interactionCount += events.length;
    model.lastUpdated = new Date();

    // Calculate overall confidence
    model.confidence = this.calculateOverallConfidence(model);

    // Calculate data span
    const timestamps = events.map(e => new Date(e.timestamp).getTime());
    const minTime = Math.min(...timestamps);
    const maxTime = Math.max(...timestamps);
    const daySpan = (maxTime - minTime) / (1000 * 60 * 60 * 24);
    model.dataSpanDays = Math.max(model.dataSpanDays, Math.ceil(daySpan));

    this.models.set(userId, model);
    this.saveToStorage();
    this.notifyListeners(userId, model);
  }

  private calculateOverallConfidence(model: UserModel): number {
    // Confidence is based on:
    // - Amount of data (interaction count)
    // - Time span of data
    // - Individual model confidences

    const dataConfidence = Math.min(model.interactionCount / 500, 1);
    const timeConfidence = Math.min(model.dataSpanDays / 14, 1);
    const expertiseConfidence = model.expertise.confidence;
    const densityConfidence = model.layout.densityConfidence;

    return (
      dataConfidence * 0.3 +
      timeConfidence * 0.2 +
      expertiseConfidence * 0.3 +
      densityConfidence * 0.2
    );
  }

  resetModel(userId: string): void {
    const model = createDefaultModel(userId);
    this.models.set(userId, model);
    this.saveToStorage();
    this.notifyListeners(userId, model);
  }

  exportModel(userId: string): UserModel | null {
    return this.getModel(userId);
  }

  importModel(model: UserModel): void {
    // Validate and migrate if needed
    if (model.modelVersion !== MODEL_VERSION) {
      model = this.migrateModel(model);
    }

    this.models.set(model.userId, model);
    this.saveToStorage();
    this.notifyListeners(model.userId, model);
  }

  private migrateModel(model: UserModel): UserModel {
    // Handle model version migrations
    // For now, just update the version
    return {
      ...createDefaultModel(model.userId),
      ...model,
      modelVersion: MODEL_VERSION,
    };
  }

  getConfidence(userId: string): number {
    const model = this.getModel(userId);
    return model?.confidence || 0;
  }

  /** Subscribe to model updates for a specific user */
  subscribe(userId: string, listener: (model: UserModel) => void): () => void {
    if (!this.listeners.has(userId)) {
      this.listeners.set(userId, new Set());
    }
    this.listeners.get(userId)!.add(listener);

    // Immediately call with current model if exists
    const model = this.getModel(userId);
    if (model) {
      listener(model);
    }

    return () => {
      this.listeners.get(userId)?.delete(listener);
    };
  }

  /** Get specific preference with confidence check */
  getPreference<K extends keyof UserModel>(
    userId: string,
    key: K,
    minConfidence = 0.3
  ): UserModel[K] | null {
    const model = this.getModel(userId);
    if (!model || model.confidence < minConfidence) {
      return null;
    }
    return model[key];
  }

  /** Merge models (useful for cross-device sync) */
  mergeModels(userId: string, remoteModel: UserModel): void {
    const localModel = this.getModel(userId);

    if (!localModel) {
      this.importModel(remoteModel);
      return;
    }

    // Use the more confident model for each section
    const merged: UserModel = {
      ...localModel,
      lastUpdated: new Date(),
      interactionCount: Math.max(
        localModel.interactionCount,
        remoteModel.interactionCount
      ),

      // Merge navigation (combine frequent sections)
      navigation: {
        ...localModel.navigation,
        frequentSections: this.mergeFrequentSections(
          localModel.navigation.frequentSections,
          remoteModel.navigation.frequentSections
        ),
      },

      // Merge filters (combine frequent filters)
      filters: {
        ...localModel.filters,
        frequentFilters: {
          ...remoteModel.filters.frequentFilters,
          ...localModel.filters.frequentFilters,
        },
        savedPresets: [
          ...localModel.filters.savedPresets,
          ...remoteModel.filters.savedPresets.filter(
            rp => !localModel.filters.savedPresets.some(lp => lp.name === rp.name)
          ),
        ],
      },

      // Use higher expertise level
      expertise: localModel.expertise.confidence >= remoteModel.expertise.confidence
        ? localModel.expertise
        : remoteModel.expertise,
    };

    merged.confidence = this.calculateOverallConfidence(merged);

    this.models.set(userId, merged);
    this.saveToStorage();
    this.notifyListeners(userId, merged);
  }

  private mergeFrequentSections(
    local: NavigationPreferences['frequentSections'],
    remote: NavigationPreferences['frequentSections']
  ): NavigationPreferences['frequentSections'] {
    const merged: Record<string, { path: string; visitCount: number; lastVisit: Date }> = {};

    for (const section of [...local, ...remote]) {
      if (!merged[section.path]) {
        merged[section.path] = section;
      } else {
        merged[section.path].visitCount += section.visitCount;
        if (section.lastVisit > merged[section.path].lastVisit) {
          merged[section.path].lastVisit = section.lastVisit;
        }
      }
    }

    return Object.values(merged)
      .sort((a, b) => b.visitCount - a.visitCount)
      .slice(0, 10);
  }
}

// Singleton instance
export const modelingService = new ModelingServiceImpl();

