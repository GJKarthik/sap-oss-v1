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
  forwardRef,
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
import { SacToolDispatchService, WidgetBindingInfo, WidgetStateTarget } from '../chat/sac-tool-dispatch.service';
import { SacAiSessionService } from '../session/sac-ai-session.service';
import {
  DEFAULT_SAC_WIDGET_SCHEMA,
  isContainerWidget,
  isFilterWidget,
  isSliderWidget,
  isTextWidget,
  SacSliderConfig,
  SacDimensionFilter,
  SacRangeFilterValue,
  SacWidgetSchema,
} from '../types/sac-widget-schema';
import {
  FilterChangeEvent,
  FilterOption,
  SacFilterCheckboxComponent,
  SacFilterDropdownComponent,
} from '../components/sac-filter.component';
import { SacSliderComponent, SliderChangeEvent } from '../components/sac-slider.component';
import { SacDividerComponent, SacHeadingComponent, SacTextBlockComponent } from '../components/sac-text.component';
import { SacFlexContainerComponent, SacGridContainerComponent } from '../components/sac-layout.component';

type WidgetDataSource = ReturnType<SacDataSourceService['create']>;
type KpiTrend = 'up' | 'down' | 'neutral' | undefined;

@Component({
  selector: 'sac-ai-data-widget',
  standalone: true,
  imports: [
    CommonModule,
    SacChartModule,
    SacTableModule,
    SacAdvancedModule,
    SacFilterDropdownComponent,
    SacFilterCheckboxComponent,
    SacSliderComponent,
    SacHeadingComponent,
    SacTextBlockComponent,
    SacDividerComponent,
    SacFlexContainerComponent,
    SacGridContainerComponent,
    forwardRef(() => SacAiDataWidgetComponent),
  ],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-ai-data-widget">
      <div *ngIf="showTitle" class="sac-ai-data-widget__title">
        {{ schema.title }}
      </div>
      <div *ngIf="statusMessage" class="sac-ai-data-widget__status">
        {{ statusMessage }}
      </div>

      <div class="sac-ai-data-widget__content">
        <ng-container *ngIf="showRenderableContent; else placeholder">
          <ng-container [ngSwitch]="schema.widgetType">
            <sac-chart
              *ngSwitchCase="'chart'"
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
              *ngSwitchCase="'table'"
              class="sac-ai-data-widget__fill"
              [title]="''"
              [showTitle]="false"
              [columns]="tableColumns"
              [rows]="tableRows"
              [loading]="loading"
            ></sac-table>

            <div *ngSwitchCase="'kpi'" class="sac-ai-data-widget__kpi-shell">
              <sac-kpi
                [title]="resolvedKpiTitle"
                [value]="kpiValue"
                [trend]="kpiTrend"
              ></sac-kpi>
            </div>

            <sac-heading
              *ngSwitchCase="'heading'"
              [content]="resolvedTextContent"
              [level]="resolvedHeadingLevel"
              [align]="resolvedTextAlign"
            ></sac-heading>

            <sac-text-block
              *ngSwitchCase="'text-block'"
              [content]="resolvedTextContent"
              [align]="resolvedTextAlign"
              [markdown]="schema.text?.markdown === true"
            ></sac-text-block>

            <sac-divider
              *ngSwitchCase="'divider'"
              [ariaLabel]="schema.ariaLabel || 'Content separator'"
            ></sac-divider>

            <sac-filter-dropdown
              *ngSwitchCase="'filter-dropdown'"
              [label]="resolvedFilterLabel"
              [dimension]="resolvedInteractiveDimension"
              [options]="filterOptions"
              [multiple]="isMultiSelectFilter"
              [placeholder]="resolvedFilterPlaceholder"
              [disabled]="!resolvedInteractiveDimension"
              [ariaLabel]="schema.ariaLabel"
              [ariaDescription]="schema.ariaDescription"
              (filterChange)="handleFilterChange($event)"
            ></sac-filter-dropdown>

            <sac-filter-checkbox
              *ngSwitchCase="'filter-checkbox'"
              [label]="resolvedFilterLabel"
              [dimension]="resolvedInteractiveDimension"
              [options]="filterOptions"
              [disabled]="!resolvedInteractiveDimension"
              [ariaDescription]="schema.ariaDescription"
              (filterChange)="handleFilterChange($event)"
            ></sac-filter-checkbox>

            <div *ngSwitchCase="'filter-date-range'" class="sac-ai-data-widget__date-range">
              <label class="sac-ai-data-widget__control-label">{{ resolvedFilterLabel }}</label>
              <div class="sac-ai-data-widget__date-inputs">
                <input
                  class="sac-ai-data-widget__date-input"
                  type="date"
                  [value]="resolvedDateRange.low"
                  [disabled]="!resolvedInteractiveDimension"
                  (change)="handleDateRangeChange('low', $event)"
                />
                <span class="sac-ai-data-widget__date-separator">to</span>
                <input
                  class="sac-ai-data-widget__date-input"
                  type="date"
                  [value]="resolvedDateRange.high"
                  [disabled]="!resolvedInteractiveDimension"
                  (change)="handleDateRangeChange('high', $event)"
                />
              </div>
            </div>

            <sac-slider
              *ngSwitchCase="'slider'"
              [label]="resolvedSliderLabel"
              [dimension]="resolvedInteractiveDimension"
              [min]="resolvedSlider.min"
              [max]="resolvedSlider.max"
              [step]="resolvedSlider.step ?? 1"
              [initialValue]="resolvedSliderInitialValue"
              [showValue]="resolvedSlider.showValue !== false"
              [format]="resolvedSlider.format ?? 'number'"
              [disabled]="!resolvedInteractiveDimension"
              [ariaLabel]="schema.ariaLabel"
              (sliderChange)="handleSliderChange($event)"
            ></sac-slider>

            <div *ngSwitchCase="'range-slider'" class="sac-ai-data-widget__range-slider">
              <label class="sac-ai-data-widget__control-label">{{ resolvedSliderLabel }}</label>
              <sac-slider
                [label]="'Low'"
                [dimension]="resolvedInteractiveDimension"
                [min]="resolvedSlider.min"
                [max]="resolvedSlider.max"
                [step]="resolvedSlider.step ?? 1"
                [initialValue]="resolvedRangeSlider.low"
                [showValue]="resolvedSlider.showValue !== false"
                [format]="resolvedSlider.format ?? 'number'"
                [disabled]="!resolvedInteractiveDimension"
                (sliderChange)="handleRangeSliderChange('low', $event)"
              ></sac-slider>
              <sac-slider
                [label]="'High'"
                [dimension]="resolvedInteractiveDimension"
                [min]="resolvedSlider.min"
                [max]="resolvedSlider.max"
                [step]="resolvedSlider.step ?? 1"
                [initialValue]="resolvedRangeSlider.high"
                [showValue]="resolvedSlider.showValue !== false"
                [format]="resolvedSlider.format ?? 'number'"
                [disabled]="!resolvedInteractiveDimension"
                (sliderChange)="handleRangeSliderChange('high', $event)"
              ></sac-slider>
            </div>

            <sac-flex-container
              *ngSwitchCase="'flex-container'"
              [direction]="resolvedFlexDirection"
              [justify]="resolvedFlexJustify"
              [align]="resolvedFlexAlign"
              [gap]="resolvedLayoutGap"
              [wrap]="resolvedFlexWrap"
              role="group"
              [ariaLabel]="schema.ariaLabel || schema.title || 'Analytics workspace'"
            >
              <sac-ai-data-widget
                *ngFor="let child of resolvedChildren; trackBy: trackByChild"
                class="sac-ai-data-widget__child"
                [schemaOverride]="buildChildSchema(child)"
                [interactiveTarget]="false"
              ></sac-ai-data-widget>
            </sac-flex-container>

            <sac-grid-container
              *ngSwitchCase="'grid-container'"
              [columns]="resolvedGridColumns"
              [rows]="resolvedGridRows"
              [gap]="resolvedLayoutGap"
              role="group"
              [ariaLabel]="schema.ariaLabel || schema.title || 'Analytics workspace'"
            >
              <sac-ai-data-widget
                *ngFor="let child of resolvedChildren; trackBy: trackByChild"
                class="sac-ai-data-widget__child"
                [schemaOverride]="buildChildSchema(child)"
                [interactiveTarget]="false"
              ></sac-ai-data-widget>
            </sac-grid-container>
          </ng-container>
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
    .sac-ai-data-widget__child {
      min-width: 0;
      min-height: 200px;
      border: 1px solid #e5e5e5;
      border-radius: 12px;
      background: linear-gradient(180deg, #ffffff 0%, #fafcff 100%);
      box-shadow: 0 10px 24px rgba(15, 36, 64, 0.06);
      padding: 12px;
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
    .sac-ai-data-widget__date-range,
    .sac-ai-data-widget__range-slider {
      display: flex;
      flex-direction: column;
      gap: 12px;
      width: 100%;
      padding: 12px;
    }
    .sac-ai-data-widget__control-label {
      font-size: 12px;
      font-weight: 700;
      color: #5b738b;
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }
    .sac-ai-data-widget__date-inputs {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .sac-ai-data-widget__date-input {
      flex: 1;
      min-height: 40px;
      border: 1px solid #89919a;
      border-radius: 8px;
      padding: 8px 12px;
      font: inherit;
      background: #fff;
      color: #32363a;
    }
    .sac-ai-data-widget__date-separator {
      color: #5b738b;
      font-size: 12px;
      text-transform: uppercase;
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
  @Input() schemaOverride?: Partial<SacWidgetSchema>;
  @Input() interactiveTarget = true;

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
  private stateSyncGeneration = 0;
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
    if (isTextWidget(this.schema) || isContainerWidget(this.schema) || isSliderWidget(this.schema) || isFilterWidget(this.schema)) {
      return true;
    }

    return Boolean(this.schema.modelId && this.hasBindings);
  }

  get showTitle(): boolean {
    return Boolean(this.schema.title && this.schema.widgetType !== 'kpi' && this.schema.widgetType !== 'heading');
  }

  get resolvedTextContent(): string {
    return this.schema.text?.content?.trim() || this.schema.subtitle || this.schema.title || 'Generated content';
  }

  get resolvedHeadingLevel(): 1 | 2 | 3 | 4 | 5 | 6 {
    return this.schema.text?.level ?? 2;
  }

  get resolvedTextAlign(): 'left' | 'center' | 'right' {
    return this.schema.text?.align ?? 'left';
  }

  get resolvedChildren(): SacWidgetSchema[] {
    return this.schema.children ?? [];
  }

  get resolvedFilterLabel(): string {
    return this.schema.title || this.schema.dimensions[0] || 'Filter';
  }

  get resolvedFilterPlaceholder(): string {
    return `Select ${this.resolvedFilterLabel.toLowerCase()}…`;
  }

  get resolvedInteractiveDimension(): string {
    return this.schema.slider?.dimension
      || this.schema.filters?.[0]?.dimension
      || this.schema.dimensions[0]
      || '';
  }

  get isMultiSelectFilter(): boolean {
    return this.schema.widgetType === 'filter-checkbox'
      || this.schema.filters?.[0]?.filterType === 'MultipleValue'
      || this.schema.filters?.[0]?.filterType === 'ExcludeValue';
  }

  get resolvedDateRange(): SacRangeFilterValue {
    const rangeValue = this.schema.filters?.find((filter) => filter.dimension === this.resolvedInteractiveDimension)?.value;
    if (this.isRangeValue(rangeValue)) {
      return rangeValue;
    }

    return {
      low: '',
      high: '',
    };
  }

  get resolvedSlider(): SacSliderConfig {
    return {
      min: this.schema.slider?.min ?? 0,
      max: this.schema.slider?.max ?? 100,
      step: this.schema.slider?.step ?? 1,
      value: this.schema.slider?.value,
      rangeValue: this.schema.slider?.rangeValue,
      showValue: this.schema.slider?.showValue ?? true,
      format: this.schema.slider?.format ?? 'number',
      dimension: this.schema.slider?.dimension ?? this.resolvedInteractiveDimension,
    };
  }

  get resolvedSliderLabel(): string {
    return this.schema.title || this.resolvedSlider.dimension || 'Value';
  }

  get resolvedSliderInitialValue(): number {
    const filterValue = this.schema.filters?.find((filter) => filter.dimension === this.resolvedInteractiveDimension)?.value;
    if (typeof filterValue === 'string' && filterValue !== '') {
      const numericValue = Number(filterValue);
      if (!Number.isNaN(numericValue)) {
        return numericValue;
      }
    }

    return this.resolvedSlider.value ?? this.resolvedSlider.min;
  }

  get resolvedRangeSlider(): { low: number; high: number } {
    const filterValue = this.schema.filters?.find((filter) => filter.dimension === this.resolvedInteractiveDimension)?.value;
    if (this.isRangeValue(filterValue)) {
      return {
        low: Number(filterValue.low) || this.resolvedSlider.min,
        high: Number(filterValue.high) || this.resolvedSlider.max,
      };
    }

    return this.schema.slider?.rangeValue ?? {
      low: this.resolvedSlider.min,
      high: this.resolvedSlider.max,
    };
  }

  get resolvedLayoutGap(): number {
    return Math.max(1, Number(this.schema.layout?.gap ?? 2));
  }

  get resolvedFlexDirection(): 'row' | 'column' {
    return 'direction' in (this.schema.layout ?? {}) && this.schema.layout?.direction === 'column'
      ? 'column'
      : 'row';
  }

  get resolvedFlexJustify(): 'start' | 'center' | 'end' | 'space-between' | 'space-around' {
    return 'justify' in (this.schema.layout ?? {}) && this.schema.layout?.justify
      ? this.schema.layout.justify
      : 'start';
  }

  get resolvedFlexAlign(): 'start' | 'center' | 'end' | 'stretch' {
    return 'align' in (this.schema.layout ?? {}) && this.schema.layout?.align
      ? this.schema.layout.align
      : 'stretch';
  }

  get resolvedFlexWrap(): boolean {
    return 'wrap' in (this.schema.layout ?? {}) ? Boolean(this.schema.layout?.wrap) : true;
  }

  get resolvedGridColumns(): number {
    if ('columns' in (this.schema.layout ?? {}) && typeof this.schema.layout?.columns === 'number') {
      return Math.max(1, this.schema.layout.columns);
    }
    return Math.max(1, this.resolvedChildren.length || 2);
  }

  get resolvedGridRows(): number | undefined {
    if ('rows' in (this.schema.layout ?? {}) && typeof this.schema.layout?.rows === 'number') {
      return Math.max(1, this.schema.layout.rows);
    }
    return undefined;
  }

  ngOnInit(): void {
    this.initialized = true;
    if (this.interactiveTarget) {
      this.toolDispatch.registerTarget(this);
    }
    this.applyInputSchema();
    if (this.interactiveTarget) {
      this.startStateSync();
    }
    this.scheduleDataRefresh();
  }

  ngOnChanges(changes: SimpleChanges): void {
    const modelChange = changes['modelId'];
    const modelChanged = Boolean(modelChange && modelChange.currentValue !== modelChange.previousValue);
    this.applyInputSchema();

    if (!this.initialized) {
      return;
    }

    if (modelChanged && this.interactiveTarget) {
      this.startStateSync();
    }

    this.scheduleDataRefresh();
  }

  ngOnDestroy(): void {
    this.stateSub?.unsubscribe();
    if (this.interactiveTarget) {
      this.toolDispatch.unregisterTarget();
    }
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

    if (this.schema.modelId !== previousModelId && this.interactiveTarget) {
      this.startStateSync();
    }

    this.scheduleDataRefresh();
    this.cdr.markForCheck();
  }

  async getBindingInfo(): Promise<WidgetBindingInfo> {
    return {
      modelId: this.schema.modelId,
      dimensions: [...this.schema.dimensions],
      measures: [...this.schema.measures],
      filters: [...(this.schema.filters ?? [])],
      chartType: this.schema.chartType,
      widgetType: this.schema.widgetType,
      topK: this.schema.topK,
    };
  }

  async refreshData(): Promise<void> {
    await this.refreshDataBinding();
    this.cdr.markForCheck();
  }

  handleFilterChange(event: FilterChangeEvent): void {
    this.applySchema({
      filters: [{
        dimension: event.dimension,
        value: event.value,
        filterType: event.filterType,
      }],
    });
  }

  handleDateRangeChange(boundary: 'low' | 'high', event: Event): void {
    const value = (event.target as HTMLInputElement | null)?.value ?? '';
    const nextRange = {
      ...this.resolvedDateRange,
      [boundary]: value,
    };

    this.applySchema({
      filters: [{
        dimension: this.resolvedInteractiveDimension,
        value: nextRange,
        filterType: 'RangeValue',
      }],
    });
  }

  handleSliderChange(event: SliderChangeEvent): void {
    this.applySchema({
      filters: [{
        dimension: event.dimension,
        value: String(event.value),
        filterType: 'SingleValue',
      }],
      slider: {
        ...this.resolvedSlider,
        value: typeof event.value === 'number' ? event.value : this.resolvedSlider.value,
      },
    });
  }

  handleRangeSliderChange(boundary: 'low' | 'high', event: SliderChangeEvent): void {
    const numericValue = typeof event.value === 'number' ? event.value : this.resolvedRangeSlider[boundary];
    const nextRange = {
      ...this.resolvedRangeSlider,
      [boundary]: numericValue,
    };

    this.applySchema({
      filters: [{
        dimension: event.dimension,
        value: {
          low: String(Math.min(nextRange.low, nextRange.high)),
          high: String(Math.max(nextRange.low, nextRange.high)),
        },
        filterType: 'RangeValue',
      }],
      slider: {
        ...this.resolvedSlider,
        rangeValue: {
          low: Math.min(nextRange.low, nextRange.high),
          high: Math.max(nextRange.low, nextRange.high),
        },
      },
    });
  }

  buildChildSchema(child: SacWidgetSchema): Partial<SacWidgetSchema> {
    return this.normalizeSchema({
      ...child,
      modelId: child.modelId || this.schema.modelId,
      filters: child.filters?.length ? child.filters : this.schema.filters,
    });
  }

  trackByChild(_: number, child: SacWidgetSchema): string {
    return child.id ?? `${child.widgetType}-${child.title ?? child.dimensions.join('-')}`;
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
      ...(this.schemaOverride ?? {
        widgetType: this.widgetType,
        modelId: this.modelId,
      }),
    });
    this.syncPresentation();
  }

  private startStateSync(): void {
    this.stateSub?.unsubscribe();

    if (!this.schema.modelId) {
      return;
    }

    const generation = ++this.stateSyncGeneration;

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
          if (generation !== this.stateSyncGeneration) {
            return;
          }

          if (event.type === 'STATE_DELTA') {
            this.applyStateSyncSnapshot(event.delta as Partial<SacWidgetSchema>);
            return;
          }

          if (event.name === 'UI_SCHEMA_SNAPSHOT') {
            this.applyStateSyncSnapshot(event.value as Partial<SacWidgetSchema>);
          }
        },
        error: (error: Error) => {
          this.statusMessage = `State sync failed: ${error.message}`;
          this.flushView();
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

    if (!this.requiresDataBinding()) {
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

  private applyStateSyncSnapshot(snapshot: Partial<SacWidgetSchema>): void {
    this.schema = this.reconcileStateSyncSchema(snapshot);
    this.syncPresentation();
    this.scheduleDataRefresh();
    this.flushView();
  }

  private flushView(): void {
    this.cdr.markForCheck();
    try {
      this.cdr.detectChanges();
    } catch {
      // Ignore view-detached races during rebootstrap/destroy paths.
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

  get filterOptions(): FilterOption[] {
    return this.buildFilterOptions(this.resultSet);
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

  private buildFilterOptions(resultSet: ResultSet | null): FilterOption[] {
    const dimension = this.resolvedInteractiveDimension;
    const selected = new Set(this.asArray(
      this.schema.filters?.find((filter) => filter.dimension === dimension)?.value,
    ));

    const options = new Map<string, FilterOption>();
    if (resultSet && dimension) {
      const dimensionIndex = resultSet.dimensions.indexOf(dimension);
      if (dimensionIndex >= 0) {
        for (const row of resultSet.data) {
          const cellValue = row[dimensionIndex]?.formatted ?? row[dimensionIndex]?.value;
          if (cellValue == null || cellValue === '') {
            continue;
          }
          const optionValue = String(cellValue);
          options.set(optionValue, {
            value: optionValue,
            label: optionValue,
            selected: selected.has(optionValue),
          });
        }
      }
    }

    if (options.size === 0) {
      for (const value of selected.size ? selected : new Set(['North', 'South', 'EMEA'])) {
        options.set(value, {
          value,
          label: value,
          selected: selected.has(value),
        });
      }
    }

    return Array.from(options.values());
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
      layout: schema.layout,
      children: schema.children?.map((child) => this.normalizeSchema(child)),
      slider: schema.slider,
      text: schema.text,
      ariaLabel: schema.ariaLabel?.trim() || undefined,
      ariaDescription: schema.ariaDescription?.trim() || undefined,
    };
  }

  private reconcileStateSyncSchema(snapshot: Partial<SacWidgetSchema>): SacWidgetSchema {
    const remote = this.normalizeSchema(snapshot);
    const current = this.schema;
    const resolvedWidgetType = current.widgetType || remote.widgetType || DEFAULT_SAC_WIDGET_SCHEMA.widgetType;

    return this.normalizeSchema({
      ...remote,
      widgetType: resolvedWidgetType,
      modelId: current.modelId || remote.modelId || this.modelId,
      dimensions: current.dimensions.length ? current.dimensions : remote.dimensions,
      measures: current.measures.length ? current.measures : remote.measures,
      filters: current.filters?.length ? this.cloneFilters(current.filters) : remote.filters,
      chartType: resolvedWidgetType === 'chart'
        ? (current.chartType || remote.chartType)
        : current.chartType,
      title: current.title || remote.title,
      subtitle: current.subtitle || remote.subtitle,
      topK: current.topK ?? remote.topK,
      layout: current.layout ?? remote.layout,
      children: current.children?.length ? current.children : remote.children,
      slider: current.slider ?? remote.slider,
      text: current.text ?? remote.text,
      ariaLabel: current.ariaLabel || remote.ariaLabel,
      ariaDescription: current.ariaDescription || remote.ariaDescription,
    });
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

  private cloneFilters(filters: SacDimensionFilter[]): SacDimensionFilter[] {
    return filters.map((filter) => ({
      ...filter,
      value: Array.isArray(filter.value)
        ? [...filter.value]
        : this.isRangeValue(filter.value)
          ? { ...filter.value }
          : filter.value,
    }));
  }

  private requiresDataBinding(): boolean {
    if (isTextWidget(this.schema) || isContainerWidget(this.schema) || isSliderWidget(this.schema)) {
      return false;
    }

    if (isFilterWidget(this.schema)) {
      return Boolean(this.schema.modelId && this.schema.dimensions.length > 0);
    }

    return Boolean(this.schema.modelId && this.hasBindings);
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
