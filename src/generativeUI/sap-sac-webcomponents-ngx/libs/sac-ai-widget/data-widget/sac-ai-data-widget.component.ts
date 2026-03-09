// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  Input,
  OnChanges,
  OnDestroy,
  OnInit,
  SimpleChanges,
  inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Subscription } from 'rxjs';
import { filter } from 'rxjs/operators';

import { SacChartModule } from '@sap-oss/sac-webcomponents-ngx/chart';
import { SacTableModule } from '@sap-oss/sac-webcomponents-ngx/table';
import { SacAdvancedModule } from '@sap-oss/sac-webcomponents-ngx/advanced';
import { SacDataSourceService } from '@sap-oss/sac-webcomponents-ngx/datasource';
import {
  ChartLegendPosition,
  ChartType,
  Feed,
  FilterValueType,
} from '@sap-oss/sac-webcomponents-ngx/core';
import type { ResultSet, FilterValue } from '@sap-oss/sac-webcomponents-ngx/datasource';
import type { TableColumn, TableRow } from '@sap-oss/sac-webcomponents-ngx/table';

import {
  SacAgUiService,
  AgUiCustomEvent,
  AgUiEvent,
  AgUiStateDeltaEvent,
} from '../ag-ui/sac-ag-ui.service';
import { SacToolDispatchService, WidgetStateTarget } from '../chat/sac-tool-dispatch.service';
import { SacAiSessionService } from '../session/sac-ai-session.service';
import {
  DEFAULT_SAC_WIDGET_SCHEMA,
  SacDimensionFilter,
  SacRangeFilterValue,
  SacWidgetSchema,
} from '../types/sac-widget-schema';

type WidgetDataSource = ReturnType<SacDataSourceService['create']>;
type KpiTrend = 'up' | 'down' | 'neutral' | undefined;

@Component({
  selector: 'sac-ai-data-widget',
  standalone: true,
  imports: [CommonModule, SacChartModule, SacTableModule, SacAdvancedModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-ai-data-widget">
      <div *ngIf="schema.title && schema.widgetType !== 'kpi'" class="sac-ai-data-widget__title">
        {{ schema.title }}
      </div>
      <div *ngIf="statusMessage" class="sac-ai-data-widget__status">
        {{ statusMessage }}
      </div>

      <div class="sac-ai-data-widget__content">
        <ng-container *ngIf="showRenderableContent; else placeholder">
          <sac-chart
            *ngIf="schema.widgetType === 'chart'"
            class="sac-ai-data-widget__fill"
            [width]="'100%'"
            [height]="'100%'"
            [showTitle]="false"
            [chartType]="resolvedChartType"
            [legendPosition]="legendPosition"
            [feeds]="chartFeeds"
            [dataSource]="dataSource"
          ></sac-chart>

          <sac-table
            *ngIf="schema.widgetType === 'table'"
            class="sac-ai-data-widget__fill"
            [title]="''"
            [showTitle]="false"
            [columns]="tableColumns"
            [rows]="tableRows"
            [loading]="loading"
          ></sac-table>

          <div *ngIf="schema.widgetType === 'kpi'" class="sac-ai-data-widget__kpi-shell">
            <sac-kpi
              [title]="resolvedKpiTitle"
              [value]="kpiValue"
              [trend]="kpiTrend"
            ></sac-kpi>
          </div>
        </ng-container>

        <ng-template #placeholder>
          <div class="sac-ai-data-widget__placeholder">
            <span *ngIf="!schema.modelId">Configure a model to display data.</span>
            <span *ngIf="schema.modelId && !hasBindings">Waiting for LLM to select dimensions or measures…</span>
          </div>
        </ng-template>
      </div>

      <div *ngIf="schema.filters?.length" class="sac-ai-data-widget__filters">
        <span
          *ngFor="let filter of schema.filters"
          class="sac-ai-data-widget__filter-chip"
        >
          {{ filter.dimension }}: {{ formatFilterValue(filter) }}
        </span>
      </div>
    </div>
  `,
  styles: [`
    .sac-ai-data-widget {
      display: flex;
      flex-direction: column;
      height: 100%;
      min-height: 0;
      font-family: '72', Arial, sans-serif;
      background: #fff;
    }
    .sac-ai-data-widget__title {
      font-size: 16px;
      font-weight: 600;
      color: #32363a;
      padding: 8px 12px 4px;
    }
    .sac-ai-data-widget__status {
      padding: 0 12px 8px;
      color: #6a6d70;
      font-size: 12px;
    }
    .sac-ai-data-widget__content {
      flex: 1;
      min-height: 0;
      overflow: hidden;
      display: flex;
    }
    .sac-ai-data-widget__fill {
      flex: 1;
      min-height: 0;
      width: 100%;
      height: 100%;
    }
    .sac-ai-data-widget__kpi-shell {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 16px;
    }
    .sac-ai-data-widget__placeholder {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      width: 100%;
      color: #8396a1;
      font-size: 13px;
      padding: 0 24px;
      text-align: center;
    }
    .sac-ai-data-widget__filters {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      padding: 4px 12px 8px;
    }
    .sac-ai-data-widget__filter-chip {
      background: #e8f2ff;
      color: #0070f2;
      border-radius: 12px;
      padding: 2px 10px;
      font-size: 12px;
    }
  `],
})
export class SacAiDataWidgetComponent implements OnInit, OnDestroy, OnChanges, WidgetStateTarget {
  @Input() widgetType: SacWidgetSchema['widgetType'] = 'chart';
  @Input() modelId = '';

  schema: SacWidgetSchema = { ...DEFAULT_SAC_WIDGET_SCHEMA };
  loading = false;
  statusMessage = '';
  resolvedChartType: ChartType = ChartType.Bar;
  legendPosition = ChartLegendPosition.Bottom;
  chartFeeds = new Map<Feed, string[]>();
  tableColumns: TableColumn[] = [];
  tableRows: TableRow[] = [];
  resolvedKpiTitle = 'KPI';
  kpiValue: number | string = 'Awaiting data';
  kpiTrend: KpiTrend = undefined;
  dataSource: WidgetDataSource | null = null;

  private initialized = false;
  private refreshQueued = false;
  private stateSub: Subscription | null = null;
  private resultSet: ResultSet | null = null;

  private readonly cdr = inject(ChangeDetectorRef);
  private readonly agUiService = inject(SacAgUiService);
  private readonly dataSourceService = inject(SacDataSourceService);
  private readonly session = inject(SacAiSessionService);
  private readonly toolDispatch = inject(SacToolDispatchService);

  get hasBindings(): boolean {
    return this.schema.dimensions.length > 0 || this.schema.measures.length > 0;
  }

  get showRenderableContent(): boolean {
    return Boolean(this.schema.modelId && this.hasBindings);
  }

  ngOnInit(): void {
    this.initialized = true;
    this.toolDispatch.registerTarget(this);
    this.applyInputSchema();
    this.startStateSync();
    this.scheduleDataRefresh();
  }

  ngOnChanges(changes: SimpleChanges): void {
    const modelChange = changes['modelId'];
    const modelChanged = Boolean(modelChange && modelChange.currentValue !== modelChange.previousValue);
    this.applyInputSchema();

    if (!this.initialized) {
      return;
    }

    if (modelChanged) {
      this.startStateSync();
    }

    this.scheduleDataRefresh();
  }

  ngOnDestroy(): void {
    this.stateSub?.unsubscribe();
    this.toolDispatch.unregisterTarget();
    this.destroyDataSource();
  }

  applySchema(patch: Partial<SacWidgetSchema>): void {
    const previousModelId = this.schema.modelId;
    const nextSchema = patch.filters?.length
      ? {
          ...this.schema,
          ...patch,
          filters: this.mergeFilters(this.schema.filters ?? [], patch.filters),
        }
      : {
          ...this.schema,
          ...patch,
        };

    this.schema = this.normalizeSchema(nextSchema);
    this.syncPresentation();

    if (this.schema.modelId !== previousModelId) {
      this.startStateSync();
    }

    this.scheduleDataRefresh();
    this.cdr.markForCheck();
  }

  async getBindingInfo(): Promise<{ modelId: string; dimensions: string[]; measures: string[] }> {
    return {
      modelId: this.schema.modelId,
      dimensions: [...this.schema.dimensions],
      measures: [...this.schema.measures],
    };
  }

  formatFilterValue(filter: SacDimensionFilter): string {
    if (Array.isArray(filter.value)) {
      return filter.value.join(', ');
    }

    if (this.isRangeValue(filter.value)) {
      return `${filter.value.low} - ${filter.value.high}`;
    }

    return String(filter.value ?? 'All');
  }

  private applyInputSchema(): void {
    this.schema = this.normalizeSchema({
      ...this.schema,
      widgetType: this.widgetType,
      modelId: this.modelId,
    });
    this.syncPresentation();
  }

  private startStateSync(): void {
    this.stateSub?.unsubscribe();

    if (!this.schema.modelId) {
      return;
    }

    this.stateSub = this.agUiService
      .run({
        message: '__state_sync__',
        modelId: this.schema.modelId,
        threadId: this.session.getThreadId(),
      })
      .pipe(
        filter((event: AgUiEvent): event is AgUiStateDeltaEvent | AgUiCustomEvent =>
          event.type === 'STATE_DELTA' || event.type === 'CUSTOM',
        ),
      )
      .subscribe({
        next: (event: AgUiStateDeltaEvent | AgUiCustomEvent) => {
          if (event.type === 'STATE_DELTA') {
            this.applySchema(event.delta as Partial<SacWidgetSchema>);
            return;
          }

          if (event.name === 'UI_SCHEMA_SNAPSHOT') {
            this.applySchema(event.value as Partial<SacWidgetSchema>);
          }
        },
        error: (error: Error) => {
          this.statusMessage = `State sync failed: ${error.message}`;
          this.cdr.markForCheck();
        },
      });
  }

  private scheduleDataRefresh(): void {
    if (!this.initialized || this.refreshQueued) {
      return;
    }

    this.refreshQueued = true;
    queueMicrotask(() => {
      this.refreshQueued = false;
      void this.refreshDataBinding();
    });
  }

  private async refreshDataBinding(): Promise<void> {
    if (!this.schema.modelId) {
      this.loading = false;
      this.statusMessage = '';
      this.resultSet = null;
      this.destroyDataSource();
      this.syncPresentation();
      this.cdr.markForCheck();
      return;
    }

    if (!this.hasBindings) {
      this.loading = false;
      this.statusMessage = '';
      this.resultSet = null;
      this.syncPresentation();
      this.cdr.markForCheck();
      return;
    }

    try {
      const dataSource = this.ensureDataSource();
      await this.configureFilters(dataSource);

      if (this.schema.widgetType === 'chart') {
        this.statusMessage = '';
        this.resultSet = null;
        this.syncPresentation();
        this.cdr.markForCheck();
        return;
      }

      this.loading = true;
      this.statusMessage = '';
      this.cdr.markForCheck();

      const resultSet = await dataSource.getData();
      this.resultSet = resultSet;
      this.syncPresentation(resultSet);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown error';
      this.resultSet = null;
      this.statusMessage = `Live data unavailable; showing binding preview. (${message})`;
      this.syncPresentation();
    } finally {
      this.loading = false;
      this.cdr.markForCheck();
    }
  }

  private ensureDataSource(): WidgetDataSource {
    if (this.dataSource && this.dataSource.modelId === this.schema.modelId) {
      return this.dataSource;
    }

    this.destroyDataSource();
    this.dataSource = this.dataSourceService.create(this.schema.modelId);
    return this.dataSource;
  }

  private async configureFilters(dataSource: WidgetDataSource): Promise<void> {
    dataSource.pause();
    try {
      await dataSource.clearFilters();

      for (const filter of this.schema.filters ?? []) {
        const value = this.toFilterValue(filter);
        if (value) {
          await dataSource.setFilter(filter.dimension, value);
        }
      }
    } finally {
      dataSource.resume();
    }
  }

  private destroyDataSource(): void {
    if (!this.dataSource) {
      return;
    }

    this.dataSourceService.destroy(this.dataSource.id);
    this.dataSource = null;
  }

  private syncPresentation(resultSet: ResultSet | null = this.resultSet): void {
    this.resolvedChartType = this.resolveChartType(this.schema.chartType);
    this.chartFeeds = this.buildChartFeeds();
    this.tableColumns = this.buildTableColumns(resultSet);
    this.tableRows = this.limitRows(
      resultSet ? this.buildRowsFromResultSet(resultSet) : this.buildPreviewRows(),
    );

    const kpiPreview = resultSet ? this.buildKpiFromResultSet(resultSet) : this.buildPreviewKpi();
    this.resolvedKpiTitle = this.schema.title?.trim() || kpiPreview.title;
    this.kpiValue = kpiPreview.value;
    this.kpiTrend = kpiPreview.trend;
  }

  private buildChartFeeds(): Map<Feed, string[]> {
    const feeds = new Map<Feed, string[]>();
    const dimensions = [...this.schema.dimensions];
    const measures = [...this.schema.measures];

    if (dimensions.length) {
      feeds.set(Feed.CategoryAxis, [dimensions[0]]);
    }

    if (measures.length) {
      feeds.set(Feed.ValueAxis, measures);
    }

    if (dimensions.length > 1) {
      feeds.set(Feed.Color, dimensions.slice(1));
    }

    return feeds;
  }

  private buildTableColumns(resultSet: ResultSet | null): TableColumn[] {
    const columnIds = resultSet
      ? [...resultSet.dimensions, ...resultSet.measures]
      : [...this.schema.dimensions, ...this.schema.measures];

    return columnIds.map((id) => ({
      id,
      label: id,
      sortable: true,
      align: this.schema.measures.includes(id) ? 'right' : 'left',
    }));
  }

  private buildRowsFromResultSet(resultSet: ResultSet): TableRow[] {
    const columnIds = [...resultSet.dimensions, ...resultSet.measures];

    return resultSet.data.map((cells, rowIndex) => {
      const row: TableRow = { id: `row-${rowIndex + 1}` };

      columnIds.forEach((columnId, columnIndex) => {
        const cell = cells[columnIndex];
        row[columnId] = cell?.formatted ?? cell?.value ?? '';
      });

      return row;
    });
  }

  private buildPreviewRows(): TableRow[] {
    const rowCount = Math.min(this.schema.topK ?? 3, 3);
    const dimensions = this.schema.dimensions.length ? this.schema.dimensions : ['Dimension'];
    const measures = this.schema.measures.length ? this.schema.measures : ['Value'];

    return Array.from({ length: Math.max(1, rowCount) }, (_, index) => {
      const row: TableRow = { id: `preview-${index + 1}` };

      dimensions.forEach((dimension, dimensionIndex) => {
        row[dimension] = dimensionIndex === 0
          ? `Member ${index + 1}`
          : `Group ${dimensionIndex}-${index + 1}`;
      });

      measures.forEach((measure, measureIndex) => {
        row[measure] = 1000 - index * 125 - measureIndex * 25;
      });

      return row;
    });
  }

  private buildKpiFromResultSet(resultSet: ResultSet): { title: string; value: number | string; trend: KpiTrend } {
    const measureTitle = resultSet.measures[0] ?? this.schema.measures[0] ?? 'KPI';
    const measureIndex = resultSet.dimensions.length;
    const currentCell = resultSet.data[0]?.[measureIndex];
    const previousCell = resultSet.data[1]?.[measureIndex];
    const currentValue = this.toNumber(currentCell?.value ?? currentCell?.formatted);
    const previousValue = this.toNumber(previousCell?.value ?? previousCell?.formatted);

    return {
      title: measureTitle,
      value: currentValue ?? currentCell?.formatted ?? currentCell?.value ?? 'No data',
      trend: this.resolveTrend(currentValue, previousValue),
    };
  }

  private buildPreviewKpi(): { title: string; value: number | string; trend: KpiTrend } {
    return {
      title: this.schema.measures[0] ?? this.schema.dimensions[0] ?? 'KPI',
      value: 'Preview',
      trend: undefined,
    };
  }

  private limitRows(rows: TableRow[]): TableRow[] {
    if (!this.schema.topK || this.schema.topK < 1) {
      return rows;
    }

    return rows.slice(0, this.schema.topK);
  }

  private toFilterValue(filter: SacDimensionFilter): FilterValue | null {
    const filterType = filter.filterType ?? 'SingleValue';

    switch (filterType) {
      case 'AllValue':
        return {
          type: FilterValueType.AllValue,
          dimension: filter.dimension,
        } as FilterValue;
      case 'ExcludeValue':
        return {
          type: FilterValueType.ExcludeValue,
          dimension: filter.dimension,
          values: this.asArray(filter.value),
        } as FilterValue;
      case 'MultipleValue':
        return {
          type: FilterValueType.MultipleValue,
          dimension: filter.dimension,
          values: this.asArray(filter.value),
        } as FilterValue;
      case 'RangeValue': {
        if (!this.isRangeValue(filter.value)) {
          return null;
        }

        return {
          type: FilterValueType.RangeValue,
          dimension: filter.dimension,
          low: filter.value.low,
          high: filter.value.high,
        } as FilterValue;
      }
      case 'SingleValue':
      default: {
        const [value] = this.asArray(filter.value);
        return {
          type: FilterValueType.SingleValue,
          dimension: filter.dimension,
          value: value ?? '',
        } as FilterValue;
      }
    }
  }

  private resolveChartType(chartType: string | undefined): ChartType {
    if (!chartType) {
      return ChartType.Bar;
    }

    const normalized = chartType.trim().toLowerCase();
    const match = (Object.values(ChartType) as string[]).find((value) => value.toLowerCase() === normalized);
    return (match as ChartType | undefined) ?? ChartType.Bar;
  }

  private resolveTrend(currentValue: number | null, previousValue: number | null): KpiTrend {
    if (currentValue == null || previousValue == null) {
      return undefined;
    }

    if (currentValue > previousValue) {
      return 'up';
    }

    if (currentValue < previousValue) {
      return 'down';
    }

    return 'neutral';
  }

  private normalizeSchema(schema: Partial<SacWidgetSchema>): SacWidgetSchema {
    const topK = schema.topK == null || Number.isNaN(Number(schema.topK))
      ? undefined
      : Math.max(1, Math.trunc(Number(schema.topK)));

    return {
      ...DEFAULT_SAC_WIDGET_SCHEMA,
      ...schema,
      widgetType: schema.widgetType ?? DEFAULT_SAC_WIDGET_SCHEMA.widgetType,
      modelId: String(schema.modelId ?? ''),
      dimensions: this.normalizeStrings(schema.dimensions),
      measures: this.normalizeStrings(schema.measures),
      filters: this.normalizeFilters(schema.filters),
      chartType: schema.chartType?.trim() || undefined,
      title: schema.title?.trim() || undefined,
      subtitle: schema.subtitle?.trim() || undefined,
      topK,
    };
  }

  private normalizeStrings(values: string[] | undefined): string[] {
    return Array.from(
      new Set(
        (values ?? [])
          .map((value) => String(value).trim())
          .filter(Boolean),
      ),
    );
  }

  private normalizeFilters(filters: SacDimensionFilter[] | undefined): SacDimensionFilter[] | undefined {
    if (!filters?.length) {
      return undefined;
    }

    return filters
      .filter((filter) => Boolean(filter.dimension?.trim()))
      .map((filter) => ({
        ...filter,
        dimension: filter.dimension.trim(),
      }));
  }

  private mergeFilters(existing: SacDimensionFilter[], incoming: SacDimensionFilter[]): SacDimensionFilter[] {
    const merged = new Map<string, SacDimensionFilter>();

    for (const filter of existing) {
      merged.set(filter.dimension, filter);
    }

    for (const filter of incoming) {
      merged.set(filter.dimension, filter);
    }

    return Array.from(merged.values());
  }

  private asArray(value: SacDimensionFilter['value']): string[] {
    if (Array.isArray(value)) {
      return value.map((item) => String(item));
    }

    if (value == null || this.isRangeValue(value)) {
      return [];
    }

    return [String(value)];
  }

  private isRangeValue(value: SacDimensionFilter['value']): value is SacRangeFilterValue {
    return Boolean(
      value
      && typeof value === 'object'
      && 'low' in value
      && 'high' in value,
    );
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
