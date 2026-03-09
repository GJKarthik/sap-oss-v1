/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Table, TableColumn, sorting, ranking, export, planning cells
 *
 * Maps to: sac_widgets.mg category "Visualization" (Table-related)
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/table/ (9 handlers)
 */

import type { OperationResult, RankDirection, SortDirection } from '../types';
import type { SACRestAPIClient } from '../client';
import { Widget } from '../widgets';

// ---------------------------------------------------------------------------
// Table sub-types
// ---------------------------------------------------------------------------

export type TableAxis = 'rows' | 'columns';

export interface TableColumn {
  id: string;
  title?: string;
  width?: number;
  visible?: boolean;
  sortable?: boolean;
}

export interface TableNumberFormat {
  pattern?: string;
  decimalPlaces?: number;
}

export interface TableQuickActionsVisibility {
  filterVisible?: boolean;
  sortVisible?: boolean;
}

export interface TableRankOptions {
  measure?: string;
  count?: number;
  direction?: RankDirection;
}

export interface TableComment {
  id: string;
  row: number;
  column: number;
  text: string;
  author?: string;
  createdAt?: string;
}

export interface NavigationPanelOptions {
  visible?: boolean;
  position?: 'left' | 'right';
}

export interface ChangedCell {
  row: number;
  column: number;
  oldValue?: string;
  newValue: string;
  userId?: string;
}

export interface TableExportResult {
  content: string;
  filename: string;
  mimeType: string;
}

// ---------------------------------------------------------------------------
// Table class
// ---------------------------------------------------------------------------

export class Table extends Widget {
  // -- Data source -----------------------------------------------------------

  async getDataSource(): Promise<string> {
    return this.client.get<string>(`/table/${e(this.id)}/datasource`);
  }

  async setDataSource(dsName: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/datasource`, { name: dsName });
  }

  // -- Dimension management --------------------------------------------------

  async addDimensionToRows(dimensionId: string, position?: number): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/dimension`, { dimensionId, axis: 'rows', position });
  }

  async addDimensionToColumns(dimensionId: string, position?: number): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/dimension`, { dimensionId, axis: 'columns', position });
  }

  async removeDimension(dimensionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/dimension/${e(dimensionId)}`);
  }

  async getDimensionsOnRows(): Promise<Array<{ id: string; description?: string }>> {
    return this.client.get(`/table/${e(this.id)}/dimensions/rows`);
  }

  async getDimensionsOnColumns(): Promise<Array<{ id: string; description?: string }>> {
    return this.client.get(`/table/${e(this.id)}/dimensions/columns`);
  }

  async swapAxes(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/swapAxes`);
  }

  // -- Dimension properties ---------------------------------------------------

  async getActiveDimensionProperties(dimensionId: string): Promise<string[]> {
    return this.client.get<string[]>(`/table/${e(this.id)}/dimension/${e(dimensionId)}/properties`);
  }

  async setActiveDimensionProperties(dimensionId: string, properties: string[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/table/${e(this.id)}/dimension/${e(dimensionId)}/properties`, { properties },
    );
  }

  // -- Selection -------------------------------------------------------------

  async getSelection(): Promise<unknown> {
    return this.client.get(`/table/${e(this.id)}/selection`);
  }

  async setSelection(selection: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/selection`, selection);
  }

  async getSelections(): Promise<unknown[]> {
    return this.client.get<unknown[]>(`/table/${e(this.id)}/selections`);
  }

  async clearSelections(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/selections`);
  }

  // -- Columns ---------------------------------------------------------------

  async getColumns(): Promise<TableColumn[]> {
    return this.client.get<TableColumn[]>(`/table/${e(this.id)}/columns`);
  }

  async setColumns(columns: TableColumn[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/columns`, { columns });
  }

  async getColumnWidth(columnId: string): Promise<number> {
    return this.client.get<number>(`/table/${e(this.id)}/columns/${e(columnId)}/width`);
  }

  async setColumnWidth(columnId: string, width: number): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/columns/${e(columnId)}/width`, { width });
  }

  async freezeColumns(count: number): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/frozenColumns`, { count });
  }

  async unfreezeColumns(): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/frozenColumns`, { count: 0 });
  }

  // -- Filter ----------------------------------------------------------------

  async setDimensionFilter(dimensionId: string, memberIds: string[]): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/filter`, { dimensionId, memberIds });
  }

  async removeDimensionFilter(dimensionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/filter/${e(dimensionId)}`);
  }

  async getDimensionFilter(dimensionId: string): Promise<string[]> {
    return this.client.get<string[]>(`/table/${e(this.id)}/filter/${e(dimensionId)}`);
  }

  // -- Sort ------------------------------------------------------------------

  async setSort(dimensionId: string, order: SortDirection, propertyId?: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/sort`, { dimensionId, order, propertyId });
  }

  async removeSort(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/sort`);
  }

  // -- Rank ------------------------------------------------------------------

  async getRankOptions(): Promise<TableRankOptions> {
    return this.client.get<TableRankOptions>(`/table/${e(this.id)}/rank`);
  }

  async setRankOptions(options: TableRankOptions): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/rank`, options);
  }

  async removeRank(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/rank`);
  }

  // -- Number format ---------------------------------------------------------

  async getNumberFormat(): Promise<TableNumberFormat> {
    return this.client.get<TableNumberFormat>(`/table/${e(this.id)}/numberFormat`);
  }

  async setNumberFormat(fmt: TableNumberFormat): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/numberFormat`, fmt);
  }

  // -- Quick actions ---------------------------------------------------------

  async getQuickActionsVisibility(): Promise<TableQuickActionsVisibility> {
    return this.client.get<TableQuickActionsVisibility>(`/table/${e(this.id)}/quickActions`);
  }

  async setQuickActionsVisibility(vis: TableQuickActionsVisibility): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/quickActions`, vis);
  }

  // -- Comments --------------------------------------------------------------

  async getComments(): Promise<TableComment[]> {
    return this.client.get<TableComment[]>(`/table/${e(this.id)}/comments`);
  }

  async addComment(row: number, column: number, text: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/comments`, { row, column, text });
  }

  async removeComment(commentId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/comments/${e(commentId)}`);
  }

  async clearComments(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/table/${e(this.id)}/comments`);
  }

  // -- Planning / data entry -------------------------------------------------

  async setCellValue(row: number, column: number, value: number | string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/cell`, { row, column, value });
  }

  async getCellValue(row: number, column: number): Promise<unknown> {
    return this.client.get(`/table/${e(this.id)}/cell/${row}/${column}`);
  }

  async isPlanningEnabled(): Promise<boolean> {
    return this.client.get<boolean>(`/table/${e(this.id)}/planningEnabled`);
  }

  // -- Totals -----------------------------------------------------------------

  async setTotalsVisible(visible: boolean, position?: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/totals`, { visible, position });
  }

  async isTotalsVisible(): Promise<boolean> {
    return this.client.get<boolean>(`/table/${e(this.id)}/totals/visible`);
  }

  async setSubtotalsVisible(dimensionId: string, visible: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/table/${e(this.id)}/subtotals/${e(dimensionId)}`, { visible },
    );
  }

  // -- Title -----------------------------------------------------------------

  async getTitle(): Promise<string> {
    return this.client.get<string>(`/table/${e(this.id)}/title`);
  }

  async setTitle(title: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/title`, { title });
  }

  // -- Navigation panel ------------------------------------------------------

  async setNavigationPanelOptions(options: NavigationPanelOptions): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/table/${e(this.id)}/navigationPanel`, options);
  }

  async openNavigationPanel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/navigationPanel/open`);
  }

  async closeNavigationPanel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/navigationPanel/close`);
  }

  // -- Export ----------------------------------------------------------------

  async exportToExcel(): Promise<TableExportResult> {
    return this.client.post<TableExportResult>(`/table/${e(this.id)}/export/excel`);
  }

  async exportToPdf(): Promise<TableExportResult> {
    return this.client.post<TableExportResult>(`/table/${e(this.id)}/export/pdf`);
  }

  async exportToCsv(): Promise<TableExportResult> {
    return this.client.post<TableExportResult>(`/table/${e(this.id)}/export/csv`);
  }

  // -- Refresh ---------------------------------------------------------------

  async refresh(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/table/${e(this.id)}/refresh`);
  }

  // -- Factory ---------------------------------------------------------------

  static async getTable(client: SACRestAPIClient, widgetId: string): Promise<Table> {
    return new Table(client, widgetId);
  }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface TableEvents {
  select: (selection: unknown) => void;
  cellClick: (cell: { row: number; column: number }) => void;
  cellDoubleClick: (cell: { row: number; column: number }) => void;
  dataChanged: (changes: ChangedCell[]) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }
