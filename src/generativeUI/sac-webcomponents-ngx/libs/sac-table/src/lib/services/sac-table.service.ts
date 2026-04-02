/**
 * SAC Table Service
 *
 * Service for managing table state and data operations.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import type {
  TableRow,
  TableSortConfig,
  TableFilterConfig,
  TableSelection,
} from '../types/table.types';

const EMPTY_SELECTION: TableSelection = {
  selectedRowIds: [],
  selectedRows: [],
  allSelected: false,
};

@Injectable({ providedIn: 'root' })
export class SacTableService {
  private readonly sourceRows$ = new BehaviorSubject<TableRow[]>([]);
  private readonly rows$ = new BehaviorSubject<TableRow[]>([]);
  private readonly selection$ = new BehaviorSubject<TableSelection>(EMPTY_SELECTION);
  private readonly sortConfig$ = new BehaviorSubject<TableSortConfig | null>(null);
  private readonly filters$ = new BehaviorSubject<TableFilterConfig[]>([]);

  get currentRows$(): Observable<TableRow[]> {
    return this.rows$.asObservable();
  }

  get selectionState$(): Observable<TableSelection> {
    return this.selection$.asObservable();
  }

  get currentSort$(): Observable<TableSortConfig | null> {
    return this.sortConfig$.asObservable();
  }

  get activeFilters$(): Observable<TableFilterConfig[]> {
    return this.filters$.asObservable();
  }

  setData(rows: TableRow[]): void {
    this.sourceRows$.next([...rows]);
    this.recompute();
  }

  getData(): TableRow[] {
    return this.rows$.getValue();
  }

  getSourceData(): TableRow[] {
    return this.sourceRows$.getValue();
  }

  addRow(row: TableRow): void {
    this.sourceRows$.next([...this.sourceRows$.getValue(), row]);
    this.recompute();
  }

  updateRow(rowId: string, updates: Partial<TableRow>): void {
    this.sourceRows$.next(
      this.sourceRows$.getValue().map((row) => (
        row.id === rowId ? { ...row, ...updates } : row
      )),
    );
    this.recompute();
  }

  removeRow(rowId: string): void {
    this.sourceRows$.next(this.sourceRows$.getValue().filter((row) => row.id !== rowId));
    this.recompute();
  }

  selectRow(rowId: string, multiSelect = true): void {
    const current = this.selection$.getValue();
    const rows = this.rows$.getValue();
    const selectedIds = multiSelect
      ? Array.from(new Set([...current.selectedRowIds, rowId]))
      : [rowId];
    this.setSelection(selectedIds, rows);
  }

  deselectRow(rowId: string): void {
    const current = this.selection$.getValue();
    const rows = this.rows$.getValue();
    this.setSelection(current.selectedRowIds.filter((id) => id !== rowId), rows);
  }

  selectAll(rows: TableRow[] = this.rows$.getValue()): void {
    this.setSelection(rows.map((row) => row.id), rows);
  }

  clearSelection(): void {
    this.selection$.next({ ...EMPTY_SELECTION });
  }

  getSelection(): TableSelection {
    return this.selection$.getValue();
  }

  setSort(config: TableSortConfig): void {
    this.sortConfig$.next(config);
    this.recompute();
  }

  clearSort(): void {
    this.sortConfig$.next(null);
    this.recompute();
  }

  getSort(): TableSortConfig | null {
    return this.sortConfig$.getValue();
  }

  setFilters(filters: TableFilterConfig[]): void {
    const normalized = this.normalizeFilters(filters);
    this.filters$.next(normalized);
    this.recompute();
  }

  addFilter(filter: TableFilterConfig): void {
    const current = this.filters$.getValue().filter((candidate) => candidate.column !== filter.column);
    this.filters$.next([...current, filter]);
    this.recompute();
  }

  removeFilter(column: string): void {
    this.filters$.next(this.filters$.getValue().filter((filter) => filter.column !== column));
    this.recompute();
  }

  clearFilters(): void {
    this.filters$.next([]);
    this.recompute();
  }

  getFilteredRows(): TableRow[] {
    return this.rows$.getValue();
  }

  getFilters(): TableFilterConfig[] {
    return this.filters$.getValue();
  }

  private recompute(): void {
    let rows = [...this.sourceRows$.getValue()];
    const filters = this.filters$.getValue();
    const sortConfig = this.sortConfig$.getValue();

    if (filters.length > 0) {
      rows = rows.filter((row) => this.matchesFilters(row, filters));
    }

    if (sortConfig) {
      rows.sort((left, right) => this.compareValues(left[sortConfig.column], right[sortConfig.column], sortConfig.direction));
    }

    this.rows$.next(rows);
    this.reconcileSelection(rows);
  }

  private reconcileSelection(rows: TableRow[]): void {
    const current = this.selection$.getValue();
    const visibleIds = new Set(rows.map((row) => row.id));
    const selectedIds = current.selectedRowIds.filter((id) => visibleIds.has(id));
    this.setSelection(selectedIds, rows);
  }

  private setSelection(selectedIds: string[], rows: TableRow[]): void {
    const uniqueIds = Array.from(new Set(selectedIds));
    const selectedRows = rows.filter((row) => uniqueIds.includes(row.id));
    this.selection$.next({
      selectedRowIds: uniqueIds,
      selectedRows,
      allSelected: rows.length > 0 && selectedRows.length === rows.length,
    });
  }

  private matchesFilters(row: TableRow, filters: TableFilterConfig[]): boolean {
    return filters.every((filter) => {
      const rawValue = row[filter.column];
      const value = rawValue == null ? '' : String(rawValue);
      const filterValue = filter.value;
      const numericValue = this.toNumber(rawValue);
      const numericFilterValue = this.toNumber(filterValue);

      switch (filter.operator) {
        case 'equals':
          return value === filterValue;
        case 'contains':
          return value.toLowerCase().includes(filterValue.toLowerCase());
        case 'startsWith':
          return value.toLowerCase().startsWith(filterValue.toLowerCase());
        case 'endsWith':
          return value.toLowerCase().endsWith(filterValue.toLowerCase());
        case 'gt':
          return numericValue != null && numericFilterValue != null && numericValue > numericFilterValue;
        case 'lt':
          return numericValue != null && numericFilterValue != null && numericValue < numericFilterValue;
        case 'gte':
          return numericValue != null && numericFilterValue != null && numericValue >= numericFilterValue;
        case 'lte':
          return numericValue != null && numericFilterValue != null && numericValue <= numericFilterValue;
        default:
          return true;
      }
    });
  }

  private compareValues(left: unknown, right: unknown, direction: TableSortConfig['direction']): number {
    const leftNumber = this.toNumber(left);
    const rightNumber = this.toNumber(right);

    let result = 0;
    if (leftNumber != null && rightNumber != null) {
      result = leftNumber - rightNumber;
    } else {
      const leftString = left == null ? '' : String(left);
      const rightString = right == null ? '' : String(right);
      result = leftString.localeCompare(rightString, undefined, {
        numeric: true,
        sensitivity: 'base',
      });
    }

    return direction === 'asc' ? result : -result;
  }

  private normalizeFilters(filters: TableFilterConfig[]): TableFilterConfig[] {
    return filters
      .filter((filter) => filter.column.trim() !== '')
      .map((filter) => ({
        ...filter,
        column: filter.column.trim(),
        value: filter.value.trim(),
      }));
  }

  private toNumber(value: unknown): number | null {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }

    if (typeof value !== 'string') {
      return null;
    }

    const numeric = Number(value.replace(/[^0-9.-]/g, ''));
    return Number.isFinite(numeric) ? numeric : null;
  }
}
