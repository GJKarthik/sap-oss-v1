/**
 * Table Types
 *
 * Type definitions for SAC Table components.
 */

/** Table configuration */
export interface TableConfig {
  columns: TableColumn[];
  selectable?: boolean;
  multiSelect?: boolean;
  sortable?: boolean;
  pagination?: TablePaginationConfig;
}

/** Table column definition */
export interface TableColumn {
  id: string;
  label: string;
  type?: 'text' | 'number' | 'date' | 'currency' | 'custom';
  width?: string;
  sortable?: boolean;
  filterable?: boolean;
  visible?: boolean;
  align?: 'left' | 'center' | 'right';
  formatter?: (value: unknown) => string;
}

/** Table row data */
export interface TableRow {
  id: string;
  [key: string]: unknown;
}

/** Table cell data */
export interface TableCell {
  value: unknown;
  formatted: string;
  columnId: string;
  rowId: string;
}

/** Table selection state */
export interface TableSelection {
  selectedRowIds: string[];
  selectedRows: TableRow[];
  allSelected: boolean;
}

/** Table sort configuration */
export interface TableSortConfig {
  column: string;
  direction: 'asc' | 'desc';
}

/** Table filter configuration */
export interface TableFilterConfig {
  column: string;
  value: string;
  operator: 'equals' | 'contains' | 'startsWith' | 'endsWith' | 'gt' | 'lt' | 'gte' | 'lte';
}

/** Table pagination configuration */
export interface TablePaginationConfig {
  enabled: boolean;
  pageSize: number;
  currentPage?: number;
  totalItems?: number;
  pageSizeOptions?: number[];
}