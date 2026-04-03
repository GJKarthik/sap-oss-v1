/**
 * SAC Table Component
 *
 * Angular table/grid component for SAP Analytics Cloud.
 * Selector: sac-table (derived from mangle/sac_widget.mg)
 */

import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  EventEmitter,
  inject,
  Input,
  OnChanges,
  OnDestroy,
  OnInit,
  Output,
  SimpleChanges,
  TrackByFunction,
} from '@angular/core';
import { SacI18nService } from '@sap-oss/sac-webcomponents-ngx/core';

import { SacTableService } from '../services/sac-table.service';
import type {
  TableColumn,
  TableFilterConfig,
  TablePaginationConfig,
  TableRow,
  TableSelection,
  TableSortConfig,
} from '../types/table.types';
import type {
  TableCellClickEvent,
  TablePageChangeEvent,
  TableRowClickEvent,
  TableSelectionChangeEvent,
  TableSortChangeEvent,
} from '../types/table-events.types';

const EMPTY_SELECTION: TableSelection = {
  selectedRowIds: [],
  selectedRows: [],
  allSelected: false,
};

@Component({
  selector: 'sac-table',
  template: `
    <div class="sac-table" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <div class="sac-table__header" *ngIf="showTitle && title">
        <h3 class="sac-table__title">{{ title }}</h3>
      </div>

      <div class="sac-table__container">
        <table class="sac-table__grid">
          <thead class="sac-table__head">
            <tr>
              <th *ngIf="showSelectAll" class="sac-table__th sac-table__th--checkbox">
                <input
                  type="checkbox"
                  [checked]="allDisplayedRowsSelected"
                  [indeterminate]="selectionIndeterminate"
                  (change)="toggleSelectAll($event)"
                />
              </th>
              <th *ngIf="selectable && !multiSelect" class="sac-table__th sac-table__th--checkbox"></th>
              <th
                *ngFor="let col of columns; trackBy: trackByColumnId"
                class="sac-table__th"
                [class.sac-table__th--sortable]="col.sortable"
                [style.width]="col.width"
                [style.text-align]="resolveColumnAlignment(col)"
                (click)="col.sortable && handleSort(col)"
              >
                {{ col.label }}
                <span class="sac-table__sort-icon" *ngIf="col.sortable">
                  {{ effectiveSortConfig?.column === col.id ? (effectiveSortConfig?.direction === 'asc' ? '▲' : '▼') : '' }}
                </span>
              </th>
            </tr>
          </thead>
          <tbody class="sac-table__body">
            <tr *ngIf="showEmptyState" class="sac-table__empty-row">
              <td class="sac-table__empty-cell" [attr.colspan]="emptyStateColumnSpan">
                {{ loading ? i18n.t('table.loadingData') : i18n.t('table.noRows') }}
              </td>
            </tr>

            <tr
              *ngFor="let row of displayRows; trackBy: trackByRowId"
              class="sac-table__row"
              [class.sac-table__row--selected]="isRowSelected(row)"
              (click)="handleRowClick(row, $event)"
            >
              <td *ngIf="selectable" class="sac-table__td sac-table__td--checkbox">
                <input
                  type="checkbox"
                  [checked]="isRowSelected(row)"
                  (click)="$event.stopPropagation()"
                  (change)="toggleRowSelection(row, $event)"
                />
              </td>
              <td
                *ngFor="let col of columns; trackBy: trackByColumnId"
                class="sac-table__td"
                [style.text-align]="resolveColumnAlignment(col)"
                (click)="handleCellClick(row, col, $event)"
              >
                {{ formatCellValue(row[col.id], col) }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="sac-table__footer" *ngIf="hasPagination">
        <div class="sac-table__pagination">
          <span>{{ paginationInfo }}</span>
          <button [disabled]="currentPage <= 1" (click)="goToPage(currentPage - 1)">←</button>
          <button [disabled]="currentPage >= totalPages" (click)="goToPage(currentPage + 1)">→</button>
        </div>
      </div>

      <div class="sac-table__loading" *ngIf="loading">
        <span class="sac-table__spinner"></span>
      </div>
    </div>
  `,
  styles: [`
    .sac-table {
      position: relative;
      border: 1px solid #e5e5e5;
      border-radius: 4px;
      overflow: hidden;
      background: #fff;
    }
    .sac-table__header {
      padding: 12px 16px;
      border-bottom: 1px solid #e5e5e5;
    }
    .sac-table__title {
      margin: 0;
      font-size: 14px;
      font-weight: 600;
    }
    .sac-table__container {
      overflow-x: auto;
    }
    .sac-table__grid {
      width: 100%;
      border-collapse: collapse;
    }
    .sac-table__th {
      padding: 12px 16px;
      text-align: left;
      font-weight: 600;
      font-size: 12px;
      color: #32363a;
      background: #f5f6f7;
      border-bottom: 1px solid #e5e5e5;
      white-space: nowrap;
    }
    .sac-table__th--sortable {
      cursor: pointer;
    }
    .sac-table__th--sortable:hover {
      background: #e5e5e5;
    }
    .sac-table__th--checkbox {
      width: 40px;
      text-align: center;
    }
    .sac-table__sort-icon {
      margin-left: 4px;
      font-size: 10px;
    }
    .sac-table__td {
      padding: 10px 16px;
      font-size: 14px;
      border-bottom: 1px solid #e5e5e5;
      color: #32363a;
    }
    .sac-table__td--checkbox {
      text-align: center;
    }
    .sac-table__row:hover {
      background: #f5f6f7;
    }
    .sac-table__row--selected {
      background: #e6f0fa;
    }
    .sac-table__empty-cell {
      padding: 24px 16px;
      text-align: center;
      color: #6a6d70;
      font-size: 13px;
    }
    .sac-table__footer {
      padding: 12px 16px;
      border-top: 1px solid #e5e5e5;
      display: flex;
      justify-content: flex-end;
    }
    .sac-table__pagination {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .sac-table__pagination button {
      padding: 4px 12px;
      border: 1px solid #89919a;
      border-radius: 4px;
      background: white;
      cursor: pointer;
    }
    .sac-table__pagination button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .sac-table__loading {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: rgba(255, 255, 255, 0.8);
    }
    .sac-table__spinner {
      width: 32px;
      height: 32px;
      border: 3px solid #f3f3f3;
      border-top: 3px solid #0854a0;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }
    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [SacTableService],
})
export class SacTableComponent implements OnInit, OnChanges, OnDestroy {
  @Input() columns: TableColumn[] = [];
  @Input() rows: TableRow[] = [];
  @Input() filters: TableFilterConfig[] = [];
  @Input() title = '';
  @Input() showTitle = true;
  @Input() selectable = false;
  @Input() multiSelect = true;
  @Input() pagination?: TablePaginationConfig;
  @Input() sortConfig?: TableSortConfig;
  @Input() loading = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onCellClick = new EventEmitter<TableCellClickEvent>();
  @Output() onRowClick = new EventEmitter<TableRowClickEvent>();
  @Output() onSelectionChange = new EventEmitter<TableSelectionChangeEvent>();
  @Output() onSortChange = new EventEmitter<TableSortChangeEvent>();
  @Output() onPageChange = new EventEmitter<TablePageChangeEvent>();

  currentPage = 1;
  pageSize = 10;
  private internalSortConfig: TableSortConfig | null = null;
  private selectionState: TableSelection = { ...EMPTY_SELECTION };

  readonly i18n = inject(SacI18nService);

  constructor(
    private readonly tableService: SacTableService = inject(SacTableService),
    private readonly cdr: ChangeDetectorRef = inject(ChangeDetectorRef),
  ) {}

  ngOnInit(): void {
    this.syncInputs();
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (
      changes['rows']
      || changes['filters']
      || changes['sortConfig']
      || changes['pagination']
    ) {
      this.syncInputs();
    }
  }

  ngOnDestroy(): void {
    this.tableService.clearSelection();
    this.tableService.clearFilters();
    this.tableService.clearSort();
    this.tableService.setData([]);
  }

  get effectiveSortConfig(): TableSortConfig | null {
    return this.sortConfig ?? this.internalSortConfig;
  }

  get processedRows(): TableRow[] {
    return this.tableService.getData();
  }

  get displayRows(): TableRow[] {
    if (!this.hasPagination) {
      return this.processedRows;
    }

    const start = (this.currentPage - 1) * this.pageSize;
    return this.processedRows.slice(start, start + this.pageSize);
  }

  get hasPagination(): boolean {
    return Boolean(this.pagination?.enabled);
  }

  get totalPages(): number {
    if (!this.hasPagination) {
      return 1;
    }

    return Math.max(1, Math.ceil(this.processedRows.length / this.pageSize));
  }

  get paginationInfo(): string {
    if (this.processedRows.length === 0) {
      return this.i18n.t('table.paginationEmpty');
    }

    const start = (this.currentPage - 1) * this.pageSize + 1;
    const end = Math.min(this.currentPage * this.pageSize, this.processedRows.length);
    return this.i18n.t('table.paginationInfo', { start, end, total: this.processedRows.length });
  }

  get showEmptyState(): boolean {
    return this.displayRows.length === 0;
  }

  get emptyStateColumnSpan(): number {
    return this.columns.length + (this.selectable ? 1 : 0);
  }

  get showSelectAll(): boolean {
    return this.selectable && this.multiSelect;
  }

  get allDisplayedRowsSelected(): boolean {
    return this.displayRows.length > 0
      && this.displayRows.every((row) => this.selectionState.selectedRowIds.includes(row.id));
  }

  get selectionIndeterminate(): boolean {
    const selectedVisibleCount = this.displayRows.filter((row) => this.selectionState.selectedRowIds.includes(row.id)).length;
    return selectedVisibleCount > 0 && selectedVisibleCount < this.displayRows.length;
  }

  readonly trackByColumnId: TrackByFunction<TableColumn> = (_, column) => column.id;
  readonly trackByRowId: TrackByFunction<TableRow> = (_, row) => row.id;

  isRowSelected(row: TableRow): boolean {
    return this.selectionState.selectedRowIds.includes(row.id);
  }

  formatCellValue(value: unknown, column: TableColumn): string {
    if (typeof column.formatter === 'function') {
      return column.formatter(value);
    }

    return value == null ? '' : String(value);
  }

  resolveColumnAlignment(column: TableColumn): string {
    return column.align ?? 'left';
  }

  toggleSelectAll(event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    if (checked) {
      this.tableService.selectAll(this.displayRows);
    } else {
      this.tableService.clearSelection();
    }
    this.syncSelectionState();
    this.emitSelectionChange();
  }

  toggleRowSelection(row: TableRow, event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    if (checked) {
      this.tableService.selectRow(row.id, this.multiSelect);
    } else {
      this.tableService.deselectRow(row.id);
    }
    this.syncSelectionState();
    this.emitSelectionChange();
  }

  handleRowClick(row: TableRow, event: MouseEvent): void {
    this.onRowClick.emit({ row, originalEvent: event });
  }

  handleCellClick(row: TableRow, column: TableColumn, event: MouseEvent): void {
    event.stopPropagation();
    this.onCellClick.emit({
      row,
      column,
      value: row[column.id],
      originalEvent: event,
    });
  }

  handleSort(column: TableColumn): void {
    const nextDirection: TableSortConfig['direction'] =
      this.effectiveSortConfig?.column === column.id && this.effectiveSortConfig.direction === 'asc'
        ? 'desc'
        : 'asc';
    const nextSort = { column: column.id, direction: nextDirection };

    this.internalSortConfig = nextSort;
    this.applySorting();
    this.cdr.markForCheck();
    this.onSortChange.emit(nextSort);
  }

  goToPage(page: number): void {
    const nextPage = Math.min(Math.max(page, 1), this.totalPages);
    if (nextPage === this.currentPage) {
      return;
    }

    this.currentPage = nextPage;
    this.cdr.markForCheck();
    this.onPageChange.emit({
      page: this.currentPage,
      pageSize: this.pageSize,
      totalItems: this.processedRows.length,
    });
  }

  private syncInputs(): void {
    this.syncPaginationConfig();
    this.tableService.setData(this.rows);
    this.tableService.setFilters(this.filters);
    this.applySorting();
    this.syncSelectionState();
    this.clampCurrentPage();
    this.cdr.markForCheck();
  }

  private syncPaginationConfig(): void {
    this.pageSize = this.pagination?.pageSize || 10;
    if (this.pagination?.currentPage != null) {
      this.currentPage = this.pagination.currentPage;
    }
  }

  private applySorting(): void {
    const sort = this.effectiveSortConfig;
    if (sort) {
      this.tableService.setSort(sort);
      return;
    }

    this.tableService.clearSort();
  }

  private syncSelectionState(): void {
    this.selectionState = this.tableService.getSelection();
  }

  private clampCurrentPage(): void {
    this.currentPage = Math.min(Math.max(this.currentPage, 1), this.totalPages);
  }

  private emitSelectionChange(): void {
    this.onSelectionChange.emit({
      selectedRows: this.selectionState.selectedRows,
      selectedCount: this.selectionState.selectedRows.length,
    });
    this.cdr.markForCheck();
  }
}
