/**
 * Table Event Types
 *
 * Event type definitions for SAC Table components.
 */

import type { TableColumn, TableRow } from './table.types';

/** Cell click event */
export interface TableCellClickEvent {
  row: TableRow;
  column: TableColumn;
  value: unknown;
  originalEvent: MouseEvent;
}

/** Row click event */
export interface TableRowClickEvent {
  row: TableRow;
  originalEvent: MouseEvent;
}

/** Selection change event */
export interface TableSelectionChangeEvent {
  selectedRows: TableRow[];
  selectedCount: number;
}

/** Sort change event */
export interface TableSortChangeEvent {
  column: string;
  direction: 'asc' | 'desc';
}

/** Page change event */
export interface TablePageChangeEvent {
  page: number;
  pageSize: number;
  totalItems: number;
}