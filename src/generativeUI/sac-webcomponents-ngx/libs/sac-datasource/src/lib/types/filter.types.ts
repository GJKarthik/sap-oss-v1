/**
 * Filter Types
 *
 * Type definitions for SAC DataSource filtering.
 * Derived from mangle/sac_datasource.mg filter_value_type, filter_operation facts.
 */

import { FilterValueType } from '@sap-oss/sac-ngx-core';

/** Base filter value interface */
export interface FilterValue {
  type: FilterValueType;
  dimension?: string;
  exclude?: boolean;
}

/** Single value filter (from mangle filter_operation "equal" fact) */
export interface SingleFilterValue extends FilterValue {
  type: FilterValueType.SingleValue;
  value: string;
  operator?: 'equal' | 'not_equal' | 'contains' | 'starts_with' | 'ends_with';
}

/** Multiple value filter (from mangle filter_operation "in" fact) */
export interface MultipleFilterValue extends FilterValue {
  type: FilterValueType.MultipleValue;
  values: string[];
}

/** Range value filter (from mangle filter_operation "between" fact) */
export interface RangeFilterValue extends FilterValue {
  type: FilterValueType.RangeValue;
  low: string;
  high: string;
  lowInclusive?: boolean;
  highInclusive?: boolean;
}

/** All value filter (no filter applied) */
export interface AllFilterValue extends FilterValue {
  type: FilterValueType.AllValue;
}

/** Exclude filter value */
export interface ExcludeFilterValue extends FilterValue {
  type: FilterValueType.ExcludeValue;
  values: string[];
}

/** Filter configuration */
export interface FilterConfig {
  dimension: string;
  filterType: FilterValueType;
  caseSensitive?: boolean;
  allowMultiple?: boolean;
  mandatory?: boolean;
}

/** Filter state for a datasource */
export interface FilterState {
  dimension: string;
  value: FilterValue;
  appliedAt: Date;
  source: 'user' | 'linked' | 'variable' | 'api';
}

/** Filter change event */
export interface FilterChangeEvent {
  dimension: string;
  previousValue?: FilterValue;
  newValue?: FilterValue;
  action: 'add' | 'update' | 'remove' | 'clear';
}
