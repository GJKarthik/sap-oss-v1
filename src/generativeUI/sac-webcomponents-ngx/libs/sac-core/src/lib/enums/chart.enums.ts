/**
 * Chart Enums
 *
 * Re-exports shared enums from the package SDK bundle (single source of truth).
 * ChartSelectionMode, ChartAxisType, ReferenceLineType are NGX-only extras — kept below.
 */
export { ChartType, Feed, ChartLegendPosition, ForecastType } from '@sap-oss/sac-sdk';

/** Chart data point selection mode */
export enum ChartSelectionMode {
  Single = 'SINGLE',
  Multiple = 'MULTIPLE',
  None = 'NONE',
}

/** Chart axis type */
export enum ChartAxisType {
  Category = 'CATEGORY',
  Value = 'VALUE',
  Time = 'TIME',
}

/** Chart reference line type */
export enum ReferenceLineType {
  Constant = 'CONSTANT',
  Average = 'AVERAGE',
  Min = 'MIN',
  Max = 'MAX',
  Median = 'MEDIAN',
  Percentile = 'PERCENTILE',
}
