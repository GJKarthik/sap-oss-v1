/**
 * Chart Types
 *
 * Type definitions for SAC Chart components.
 * Derived from sap-sac-webcomponents-ts/src/chart/
 */

import { ChartType, ChartLegendPosition, Feed, ForecastType } from '@sap-oss/sac-ngx-core';

/** Chart axis scale configuration */
export interface ChartAxisScale {
  min?: number;
  max?: number;
  stepSize?: number;
  autoScale?: boolean;
  logarithmic?: boolean;
}

/** Effective axis scale (calculated) */
export interface ChartAxisScaleEffective {
  min: number;
  max: number;
  stepSize: number;
  tickCount: number;
}

/** Number format for chart values */
export interface ChartNumberFormat {
  decimalPlaces?: number;
  useGrouping?: boolean;
  prefix?: string;
  suffix?: string;
  scaleFactor?: number;
  scaleLabel?: string;
}

/** Quick actions visibility configuration */
export interface ChartQuickActionsVisibility {
  showFilter?: boolean;
  showSort?: boolean;
  showRank?: boolean;
  showDrill?: boolean;
  showExport?: boolean;
}

/** Chart rank options */
export interface ChartRankOptions {
  enabled: boolean;
  direction: 'Top' | 'Bottom';
  count: number;
  dimension?: string;
  measure?: string;
}

/** Chart sort options */
export interface ChartSortOptions {
  dimension?: string;
  measure?: string;
  direction: 'Ascending' | 'Descending';
}

/** Chart legend configuration */
export interface ChartLegendConfig {
  show: boolean;
  position: ChartLegendPosition;
  maxItems?: number;
  interactive?: boolean;
}

/** Forecast configuration */
export interface ForecastConfig {
  enabled: boolean;
  type: ForecastType;
  periods: number;
  showConfidenceInterval?: boolean;
  confidenceLevel?: number;
}

/** Forecast result */
export interface ForecastResult {
  values: number[];
  confidenceUpper?: number[];
  confidenceLower?: number[];
  accuracy?: number;
}

/** Smart grouping configuration */
export interface SmartGroupingConfig {
  enabled: boolean;
  threshold?: number;
  label?: string;
}

/** Feed configuration for chart */
export interface FeedConfig {
  feed: Feed;
  members: string[];
}

/** Data change insight */
export interface DataChangeInsight {
  type: string;
  dimension: string;
  member: string;
  changeValue: number;
  changePercent: number;
  description: string;
}

/** Data point for chart interactions */
export interface DataPoint {
  dimension: string;
  member: string;
  measure: string;
  value: number;
  formattedValue: string;
  coordinates?: { x: number; y: number };
}

/** Legend item state */
export interface ChartLegendItem {
  label: string;
  color: string;
  isVisible: boolean;
}

/** Minimal chart datasource contract */
export interface ChartDataSourceLike {
  getData(): Promise<ChartResultSetLike>;
}

/** Minimal chart result-set contract */
export interface ChartResultSetLike {
  data: unknown[][];
  dimensions: string[];
  measures: string[];
}

/** Full chart configuration */
export interface ChartConfig {
  chartType: ChartType;
  showLegend: boolean;
  legendPosition: ChartLegendPosition;
  enableZoom: boolean;
  enableDrillDown: boolean;
  axisScale?: ChartAxisScale;
  numberFormat?: ChartNumberFormat;
  forecast?: ForecastConfig;
  feeds?: Map<Feed, string[]>;
  colorPalette?: string[];
  dataSource?: ChartDataSourceLike | null;
}
