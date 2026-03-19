/**
 * Adaptive UI Architecture — Preference Inference
 * 
 * Infers UI preferences from user behavior patterns.
 */

import type {
  LayoutPreferences,
  TablePreferences,
  FilterPreferences,
  VisualizationPreferences,
} from '../types';
import type { InteractionEvent } from '../../capture/types';

// ============================================================================
// DENSITY PREFERENCE
// ============================================================================

export function inferDensity(
  events: InteractionEvent[],
  current: LayoutPreferences
): LayoutPreferences {
  const scrollEvents = events.filter(e => e.type === 'scroll');
  const expandEvents = events.filter(e => e.type === 'expand');
  const collapseEvents = events.filter(e => e.type === 'collapse');
  
  // Calculate scroll intensity (high scroll = content too dense or too spread)
  const scrollIntensity = scrollEvents.length / Math.max(events.length, 1);
  
  // Calculate expand/collapse ratio
  const expandRatio = expandEvents.length / Math.max(expandEvents.length + collapseEvents.length, 1);
  
  let density = current.density;
  let confidenceDelta = 0;
  
  // High collapse ratio suggests user wants compact view
  if (collapseEvents.length > expandEvents.length * 2 && events.length > 30) {
    density = 'compact';
    confidenceDelta = 0.15;
  }
  // High expand ratio suggests user wants more space
  else if (expandEvents.length > collapseEvents.length * 2 && events.length > 30) {
    density = 'spacious';
    confidenceDelta = 0.15;
  }
  // High scroll with mostly collapses = too much scrolling, go compact
  else if (scrollIntensity > 0.3 && expandRatio < 0.3) {
    density = 'compact';
    confidenceDelta = 0.1;
  }
  
  // Track which panels user typically collapses
  const collapsedPanels = collapseEvents
    .map(e => e.target)
    .filter((v, i, a) => a.indexOf(v) === i);
  
  // Track panel order from interactions
  const panelInteractions: Record<string, number> = {};
  for (const event of events) {
    if (event.metadata.panel) {
      const panel = event.metadata.panel as string;
      panelInteractions[panel] = (panelInteractions[panel] || 0) + 1;
    }
  }
  
  const panelOrder = Object.entries(panelInteractions)
    .sort((a, b) => b[1] - a[1])
    .map(([panel]) => panel);
  
  return {
    ...current,
    density,
    densityConfidence: Math.min(current.densityConfidence + confidenceDelta, 0.95),
    defaultCollapsed: [...new Set([...current.defaultCollapsed, ...collapsedPanels])],
    panelOrder: panelOrder.length > 0 ? panelOrder : current.panelOrder,
  };
}

// ============================================================================
// TABLE PREFERENCES
// ============================================================================

export function inferTablePrefs(
  events: InteractionEvent[],
  current: TablePreferences
): TablePreferences {
  const tableEvents = events.filter(e => e.componentType === 'table');
  
  // Track sort preferences
  const sortCounts: Record<string, Record<string, number>> = {};
  const sortEvents = tableEvents.filter(e => e.type === 'sort');
  
  for (const event of sortEvents) {
    const tableId = event.componentId;
    const column = event.metadata.column as string;
    const direction = (event.metadata.direction as string) || 'asc';
    const key = `${column}:${direction}`;
    
    if (!sortCounts[tableId]) sortCounts[tableId] = {};
    sortCounts[tableId][key] = (sortCounts[tableId][key] || 0) + 1;
  }
  
  // Get most frequent sort for each table
  const defaultSort = { ...current.defaultSort };
  for (const [tableId, counts] of Object.entries(sortCounts)) {
    const mostFrequent = Object.entries(counts)
      .sort((a, b) => b[1] - a[1])[0];
    
    if (mostFrequent && mostFrequent[1] >= 2) {
      const [column, direction] = mostFrequent[0].split(':');
      defaultSort[tableId] = { column, direction: direction as 'asc' | 'desc' };
    }
  }
  
  // Track column visibility (which columns user scrolls to see)
  const columnVisibility = { ...current.columnVisibility };
  for (const event of tableEvents) {
    if (event.metadata.visibleColumns) {
      const tableId = event.componentId;
      const cols = event.metadata.visibleColumns as string[];
      columnVisibility[tableId] = cols;
    }
  }
  
  // Infer page size preference
  let pageSize = current.pageSize;
  const paginationEvents = tableEvents.filter(
    e => e.type === 'navigate' && typeof e.metadata.pageSize === 'number'
  );
  
  if (paginationEvents.length >= 3) {
    const sizes = paginationEvents.map(e => e.metadata.pageSize as number);
    // Use mode (most common) rather than average
    const sizeCounts: Record<number, number> = {};
    for (const size of sizes) {
      sizeCounts[size] = (sizeCounts[size] || 0) + 1;
    }
    pageSize = Number(
      Object.entries(sizeCounts).sort((a, b) => b[1] - a[1])[0][0]
    );
  }
  
  // Infer row height preference from expand/collapse patterns
  let rowHeight = current.rowHeight;
  const rowExpands = tableEvents.filter(e => e.type === 'expand').length;
  const rowCollapses = tableEvents.filter(e => e.type === 'collapse').length;
  
  if (rowExpands > rowCollapses * 2) {
    rowHeight = 'expanded';
  } else if (rowCollapses > rowExpands * 2) {
    rowHeight = 'compact';
  }
  
  return {
    ...current,
    defaultSort,
    columnVisibility,
    pageSize,
    rowHeight,
  };
}

// ============================================================================
// FILTER PREFERENCES
// ============================================================================

export function inferFilterPrefs(
  events: InteractionEvent[],
  current: FilterPreferences
): FilterPreferences {
  const filterEvents = events.filter(e => e.type === 'filter');
  
  // Track filter value frequency by context
  const filterCounts: Record<string, Record<string, number>> = {};
  
  for (const event of filterEvents) {
    const context = event.componentId || 'default';
    const field = event.metadata.field as string;
    const value = event.metadata.value;
    
    if (field && value !== undefined && value !== '' && value !== null) {
      if (!filterCounts[context]) filterCounts[context] = {};
      const key = `${field}::${JSON.stringify(value)}`;
      filterCounts[context][key] = (filterCounts[context][key] || 0) + 1;
    }
  }
  
  // Convert to frequent filters (used 2+ times)
  const frequentFilters = { ...current.frequentFilters };
  
  for (const [context, counts] of Object.entries(filterCounts)) {
    const frequent = Object.entries(counts)
      .filter(([, count]) => count >= 2)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)
      .map(([key]) => {
        const [field, valueJson] = key.split('::');
        try {
          return { field, value: JSON.parse(valueJson) };
        } catch {
          return { field, value: valueJson };
        }
      });
    
    if (frequent.length > 0) {
      frequentFilters[context] = frequent;
    }
  }
  
  // Detect auto-apply preference
  // If user often applies filters in quick succession, they prefer auto-apply
  let autoApply = current.autoApply;
  const filterTimes = filterEvents.map(e => new Date(e.timestamp).getTime());
  
  if (filterTimes.length >= 5) {
    let quickSuccessions = 0;
    for (let i = 1; i < filterTimes.length; i++) {
      if (filterTimes[i] - filterTimes[i - 1] < 1500) {
        quickSuccessions++;
      }
    }
    // If most filters are applied quickly after each other, auto-apply is preferred
    autoApply = quickSuccessions / filterTimes.length > 0.5;
  }
  
  return {
    ...current,
    frequentFilters,
    autoApply,
  };
}

