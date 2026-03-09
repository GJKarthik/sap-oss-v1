// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

export type SacWidgetType = 'chart' | 'table' | 'kpi';

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

export interface SacWidgetSchema {
  widgetType: SacWidgetType;
  modelId: string;
  dimensions: string[];
  measures: string[];
  filters?: SacDimensionFilter[];
  chartType?: string;
  title?: string;
  subtitle?: string;
  topK?: number;
}

export const DEFAULT_SAC_WIDGET_SCHEMA: SacWidgetSchema = {
  widgetType: 'chart',
  modelId: '',
  dimensions: [],
  measures: [],
};
