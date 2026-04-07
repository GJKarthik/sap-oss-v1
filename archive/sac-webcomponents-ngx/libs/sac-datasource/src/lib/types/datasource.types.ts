/**
 * DataSource Types
 *
 * Type definitions for SAC DataSource operations.
 * Derived from mangle/sac_datasource.mg specifications.
 */

import { Observable } from 'rxjs';
import type { FilterValue } from './filter.types';
import type { DimensionInfo, MeasureInfo, VariableInfo } from './metadata.types';

/** DataSource interface */
export interface DataSource {
  readonly id: string;
  readonly modelId: string;
  
  // Observable streams
  resultSet$: Observable<ResultSet | null>;
  isLoading$: Observable<boolean>;
  lastError$: Observable<Error | null>;
  
  // Query methods
  getData(): Promise<ResultSet>;
  getDimensions(): DimensionInfo[];
  getMeasures(): MeasureInfo[];
  getVariables(): VariableInfo[];
  
  // Filter methods
  setFilter(dimension: string, value: FilterValue): Promise<void>;
  removeFilter(dimension: string): Promise<void>;
  clearFilters(): Promise<void>;
  getActiveFilters(): FilterValue[];
  
  // State methods
  refresh(): Promise<void>;
  pause(): void;
  resume(): void;
  getState(): DataSourceState;
  dispose(): void;
}

/** DataSource configuration */
export interface DataSourceConfig {
  modelId: string;
  autoRefresh?: boolean;
  refreshInterval?: number;
  initialFilters?: Record<string, FilterValue>;
  initialVariables?: Record<string, unknown>;
  cacheEnabled?: boolean;
  cacheDuration?: number;
}

/** DataSource state */
export interface DataSourceState {
  id: string;
  modelId: string;
  paused: boolean;
  loading: boolean;
  hasData: boolean;
  filterCount: number;
  lastRefresh?: Date;
  error?: Error;
}

/** ResultSet from data query (from mangle resultset_property facts) */
export interface ResultSet {
  data: DataCell[][];
  dimensions: string[];
  measures: string[];
  rowCount: number;
  columnCount: number;
  metadata: ResultSetMetadata;
}

/** ResultSet metadata */
export interface ResultSetMetadata {
  modelId: string;
  queryId?: string;
  executionTime?: number;
  truncated?: boolean;
  totalRowCount?: number;
  dimensionHeaders: DimensionHeader[];
  measureHeaders: MeasureHeader[];
}

/** Dimension header in result set */
export interface DimensionHeader {
  id: string;
  name: string;
  index: number;
}

/** Measure header in result set */
export interface MeasureHeader {
  id: string;
  name: string;
  index: number;
  unit?: string;
  currency?: string;
}

/** Data cell (from mangle datacell_property facts) */
export interface DataCell {
  value: unknown;
  formatted: string;
  unit?: string;
  currency?: string;
  status: CellStatus;
}

/** Cell status */
export type CellStatus = 
  | 'normal'
  | 'error'
  | 'loading'
  | 'empty'
  | 'null'
  | 'locked'
  | 'readonly';