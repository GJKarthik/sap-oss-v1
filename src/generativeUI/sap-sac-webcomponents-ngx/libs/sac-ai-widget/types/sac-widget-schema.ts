// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

// =============================================================================
// P2-002: Expanded SAC Widget Types
// Original: 'chart' | 'table' | 'kpi' (3 types)
// Expanded: +10 types for filters, sliders, text, layouts
// =============================================================================

/** Original widget types */
export type SacWidgetTypeCore = 'chart' | 'table' | 'kpi';

/** New interactive filter types */
export type SacWidgetTypeFilter = 'filter-dropdown' | 'filter-checkbox' | 'filter-date-range';

/** New slider/range types */
export type SacWidgetTypeSlider = 'slider' | 'range-slider';

/** New text/content types */
export type SacWidgetTypeText = 'text-block' | 'heading' | 'divider';

/** Layout container types */
export type SacWidgetTypeLayout = 'grid-container' | 'flex-container';

/** All widget types combined */
export type SacWidgetType =
  | SacWidgetTypeCore
  | SacWidgetTypeFilter
  | SacWidgetTypeSlider
  | SacWidgetTypeText
  | SacWidgetTypeLayout;

// =============================================================================
// Filter Value Types
// =============================================================================

export type SacDimensionFilterType =
  | 'SingleValue'
  | 'MultipleValue'
  | 'RangeValue'
  | 'AllValue'
  | 'ExcludeValue';

export interface SacRangeFilterValue {
  low: string;
  high: string;
}

export type SacDimensionFilterValue = string | string[] | SacRangeFilterValue;

export interface SacDimensionFilter {
  dimension: string;
  value?: SacDimensionFilterValue;
  filterType?: SacDimensionFilterType;
  exclude?: boolean;
}

// =============================================================================
// P2-002: Layout Configuration
// =============================================================================

export type SacLayoutDirection = 'row' | 'column';
export type SacLayoutJustify = 'start' | 'center' | 'end' | 'space-between' | 'space-around';
export type SacLayoutAlign = 'start' | 'center' | 'end' | 'stretch';
export type SacResponsiveBreakpoint = 'xs' | 'sm' | 'md' | 'lg' | 'xl';

export interface SacLayoutConfig {
  direction?: SacLayoutDirection;
  justify?: SacLayoutJustify;
  align?: SacLayoutAlign;
  gap?: number; // in 8px grid units
  wrap?: boolean;
  /** Responsive overrides per breakpoint */
  responsive?: Partial<Record<SacResponsiveBreakpoint, Partial<SacLayoutConfig>>>;
}

export interface SacGridConfig {
  columns?: number; // default 12
  rows?: number;
  gap?: number; // in 8px grid units
  /** Responsive column counts per breakpoint */
  responsive?: Partial<Record<SacResponsiveBreakpoint, number>>;
}

// =============================================================================
// P2-002: Slider Configuration
// =============================================================================

export interface SacSliderConfig {
  min: number;
  max: number;
  step?: number;
  value?: number;
  /** For range-slider */
  rangeValue?: { low: number; high: number };
  /** Show value label */
  showValue?: boolean;
  /** Format for display (e.g., 'currency', 'percent', 'number') */
  format?: 'currency' | 'percent' | 'number';
  /** Linked dimension for filtering */
  dimension?: string;
}

// =============================================================================
// P2-002: Text Block Configuration
// =============================================================================

export type SacHeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;
export type SacTextAlign = 'left' | 'center' | 'right';

export interface SacTextConfig {
  content: string;
  level?: SacHeadingLevel; // for heading type
  align?: SacTextAlign;
  /** Render as markdown */
  markdown?: boolean;
}

// =============================================================================
// Expanded Widget Schema
// =============================================================================

export interface SacWidgetSchema {
  /** Widget type - now supports 13 types */
  widgetType: SacWidgetType;
  /** Unique ID for cross-referencing */
  id?: string;
  /** SAC Model ID (required for data widgets) */
  modelId: string;
  /** Dimensions for data binding */
  dimensions: string[];
  /** Measures for data binding */
  measures: string[];
  /** Data filters */
  filters?: SacDimensionFilter[];
  /** Chart type (for widgetType='chart') */
  chartType?: string;
  /** Display title */
  title?: string;
  /** Display subtitle */
  subtitle?: string;
  /** Top K results limit */
  topK?: number;

  // P2-002 Expansions
  /** Layout configuration (for grid/flex containers) */
  layout?: SacLayoutConfig | SacGridConfig;
  /** Child widgets (for containers) */
  children?: SacWidgetSchema[];
  /** Slider configuration */
  slider?: SacSliderConfig;
  /** Text/heading configuration */
  text?: SacTextConfig;
  // Accessibility
  /** Accessible label (for screen readers) */
  ariaLabel?: string;
  /** Accessible description */
  ariaDescription?: string;
}

export const DEFAULT_SAC_WIDGET_SCHEMA: SacWidgetSchema = {
  widgetType: 'chart',
  modelId: '',
  dimensions: [],
  measures: [],
};

// =============================================================================
// Type Guards
// =============================================================================

export function isContainerWidget(schema: SacWidgetSchema): boolean {
  return schema.widgetType === 'grid-container' || schema.widgetType === 'flex-container';
}

export function isFilterWidget(schema: SacWidgetSchema): boolean {
  return schema.widgetType.startsWith('filter-');
}

export function isSliderWidget(schema: SacWidgetSchema): boolean {
  return schema.widgetType === 'slider' || schema.widgetType === 'range-slider';
}

export function isTextWidget(schema: SacWidgetSchema): boolean {
  return schema.widgetType === 'text-block' || schema.widgetType === 'heading' || schema.widgetType === 'divider';
}

export function isDataWidget(schema: SacWidgetSchema): boolean {
  return schema.widgetType === 'chart' || schema.widgetType === 'table' || schema.widgetType === 'kpi';
}
