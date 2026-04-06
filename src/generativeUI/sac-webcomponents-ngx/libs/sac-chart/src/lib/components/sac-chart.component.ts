/**
 * SAC Chart Component
 *
 * Angular component for SAP Analytics Cloud charts.
 * Selector: sac-chart (derived from mangle/sac_widget.mg)
 */

import {
  AfterViewInit,
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  inject,
  Input,
  OnChanges,
  OnDestroy,
  Output,
  SimpleChanges,
  ViewChild,
} from '@angular/core';

import { ChartLegendPosition, ChartType, Feed } from '@sap-oss/sac-ngx-core';
import { SacChartService } from '../services/sac-chart.service';
import type {
  ChartAxisScale,
  ChartConfig,
  ChartDataSourceLike,
  ChartLegendConfig,
  ChartLegendItem,
  ChartNumberFormat,
  ForecastConfig,
} from '../types/chart.types';
import type {
  ChartDataPointClickEvent,
  ChartLegendClickEvent,
  ChartSelectionChangeEvent,
} from '../types/chart-events.types';

@Component({
  selector: 'sac-chart',
  template: `
    <div
      class="sac-chart"
      [class]="cssClass"
      [style.width]="width"
      [style.height]="height"
      [style.display]="visible ? 'flex' : 'none'"
    >
      <div class="sac-chart__header" *ngIf="showTitle && title">
        <h3 class="sac-chart__title">{{ title }}</h3>
        <p class="sac-chart__subtitle" *ngIf="subtitle">{{ subtitle }}</p>
      </div>

      <div class="sac-chart__body" [ngClass]="legendLayoutClass">
        <div class="sac-chart__legend" *ngIf="showLegendPanel">
          <button
            type="button"
            *ngFor="let item of legendItems; index as legendIndex"
            class="sac-chart__legend-item"
            [class.sac-chart__legend-item--hidden]="!item.isVisible"
            (click)="handleLegendItemClick(item, legendIndex, $event)"
          >
            <span class="sac-chart__legend-swatch" [style.background]="item.color"></span>
            <span>{{ item.label }}</span>
          </button>
        </div>

        <div class="sac-chart__canvas" #canvasContainer (click)="handleCanvasClick($event)"></div>
      </div>

      <div class="sac-chart__loading" *ngIf="loading">
        <span class="sac-chart__spinner"></span>
      </div>
      <div class="sac-chart__error" *ngIf="error">
        <span class="sac-chart__error-message">{{ error }}</span>
      </div>
    </div>
  `,
  styles: [`
    .sac-chart {
      position: relative;
      width: 100%;
      height: 100%;
      min-height: 200px;
      display: flex;
      flex-direction: column;
    }
    .sac-chart__header {
      padding: 8px 12px;
    }
    .sac-chart__title {
      margin: 0;
      font-size: 14px;
      font-weight: 600;
    }
    .sac-chart__subtitle {
      margin: 4px 0 0;
      font-size: 12px;
      color: #666;
    }
    .sac-chart__body {
      display: flex;
      flex: 1;
      min-height: 150px;
    }
    .sac-chart__body--legend-top,
    .sac-chart__body--legend-bottom {
      flex-direction: column;
    }
    .sac-chart__body--legend-left,
    .sac-chart__body--legend-right {
      flex-direction: row;
    }
    .sac-chart__canvas {
      flex: 1;
      min-height: 150px;
      cursor: pointer;
    }
    .sac-chart__canvas .sac-chart__empty-state {
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #6a6d70;
      font-size: 13px;
      text-align: center;
      padding: 0 24px;
    }
    .sac-chart__legend {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      padding: 8px 12px;
      background: #f8f9fb;
    }
    .sac-chart__body--legend-top .sac-chart__legend {
      order: 0;
      border-bottom: 1px solid #e5e5e5;
    }
    .sac-chart__body--legend-bottom .sac-chart__legend {
      order: 1;
      border-top: 1px solid #e5e5e5;
    }
    .sac-chart__body--legend-left .sac-chart__legend,
    .sac-chart__body--legend-right .sac-chart__legend {
      flex-direction: column;
      flex-wrap: nowrap;
      min-width: 160px;
      max-width: 220px;
    }
    .sac-chart__body--legend-left .sac-chart__legend {
      order: 0;
      border-right: 1px solid #e5e5e5;
    }
    .sac-chart__body--legend-right .sac-chart__legend {
      order: 1;
      border-left: 1px solid #e5e5e5;
    }
    .sac-chart__legend-item {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border: 0;
      background: transparent;
      color: #32363a;
      cursor: pointer;
      padding: 0;
      font: inherit;
      text-align: start;
    }
    .sac-chart__legend-item--hidden {
      opacity: 0.45;
    }
    .sac-chart__legend-swatch {
      width: 12px;
      height: 12px;
      border-radius: 999px;
      flex: 0 0 12px;
    }
    .sac-chart__loading {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: rgba(255, 255, 255, 0.8);
    }
    .sac-chart__spinner {
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
    .sac-chart__error {
      padding: 16px;
      text-align: center;
      color: #bb0000;
    }
    :host-context([dir='rtl']) .sac-chart__legend-item {
      text-align: end;
    }
    :host-context([dir='rtl']) .sac-chart__body--legend-left .sac-chart__legend {
      border-right: none;
      border-left: 1px solid #e5e5e5;
    }
    :host-context([dir='rtl']) .sac-chart__body--legend-right .sac-chart__legend {
      border-left: none;
      border-right: 1px solid #e5e5e5;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [SacChartService],
})
export class SacChartComponent implements AfterViewInit, OnChanges, OnDestroy {
  @Input() visible = true;
  @Input() enabled = true;
  @Input() cssClass = '';
  @Input() width = 'auto';
  @Input() height = 'auto';

  @Input() chartType: ChartType = ChartType.Bar;
  @Input() dataSource: ChartDataSourceLike | null = null;
  @Input() showLegend = true;
  @Input() legendPosition: ChartLegendPosition = ChartLegendPosition.Bottom;
  @Input() title = '';
  @Input() subtitle = '';
  @Input() showTitle = true;
  @Input() axisScale?: ChartAxisScale;
  @Input() numberFormat?: ChartNumberFormat;
  @Input() legendConfig?: ChartLegendConfig;
  @Input() forecastConfig?: ForecastConfig;
  @Input() feeds: Map<Feed, string[]> = new Map();
  @Input() colorPalette?: string[];
  @Input() enableZoom = false;
  @Input() enableDrillDown = false;

  @Output() onClick = new EventEmitter<MouseEvent>();
  @Output() onResize = new EventEmitter<{ width: number; height: number }>();
  @Output() onSelectionChange = new EventEmitter<ChartSelectionChangeEvent>();
  @Output() onDataPointClick = new EventEmitter<ChartDataPointClickEvent>();
  @Output() onLegendClick = new EventEmitter<ChartLegendClickEvent>();
  @Output() onZoom = new EventEmitter<{ zoomLevel: number }>();
  @Output() onDataLoad = new EventEmitter<void>();
  @Output() onError = new EventEmitter<Error>();

  @ViewChild('canvasContainer') canvasContainer!: ElementRef<HTMLDivElement>;

  loading = false;
  error: string | null = null;
  legendItems: ChartLegendItem[] = [];

  private viewInitialized = false;

  constructor(
    private readonly chartService: SacChartService = inject(SacChartService),
    private readonly cdr: ChangeDetectorRef = inject(ChangeDetectorRef),
  ) {}

  ngAfterViewInit(): void {
    this.viewInitialized = true;
    this.initializeChart();
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (!this.viewInitialized) {
      return;
    }

    if (
      changes['chartType']
      || changes['dataSource']
      || changes['feeds']
      || changes['colorPalette']
      || changes['axisScale']
      || changes['numberFormat']
    ) {
      this.updateChart();
    }

    if (changes['legendPosition'] || changes['showLegend']) {
      this.updateLegend();
    }
  }

  ngOnDestroy(): void {
    this.chartService.destroyChart();
  }

  get legendLayoutClass(): string {
    switch (this.legendPosition) {
      case ChartLegendPosition.Top:
        return 'sac-chart__body--legend-top';
      case ChartLegendPosition.Left:
        return 'sac-chart__body--legend-left';
      case ChartLegendPosition.Right:
        return 'sac-chart__body--legend-right';
      case ChartLegendPosition.Bottom:
      default:
        return 'sac-chart__body--legend-bottom';
    }
  }

  get showLegendPanel(): boolean {
    return this.showLegend
      && this.legendPosition !== ChartLegendPosition.None
      && this.legendItems.length > 0;
  }

  refresh(): void {
    this.loading = true;
    this.error = null;
    this.cdr.markForCheck();

    this.chartService.refreshData()
      .then(() => {
        this.loading = false;
        this.syncLegendItems();
        this.onDataLoad.emit();
        this.cdr.markForCheck();
      })
      .catch((err) => {
        this.loading = false;
        this.syncLegendItems();
        this.error = err instanceof Error ? err.message : 'Failed to load chart data';
        this.onError.emit(err instanceof Error ? err : new Error(this.error));
        this.cdr.markForCheck();
      });
  }

  getConfig(): ChartConfig {
    return {
      chartType: this.chartType,
      showLegend: this.showLegend,
      legendPosition: this.legendPosition,
      enableZoom: this.enableZoom,
      enableDrillDown: this.enableDrillDown,
      axisScale: this.axisScale,
      numberFormat: this.numberFormat,
      feeds: this.feeds,
      colorPalette: this.colorPalette,
      dataSource: this.dataSource,
    };
  }

  exportAsImage(format: 'png' | 'svg' = 'png'): Promise<Blob> {
    return this.chartService.exportChart(format);
  }

  handleCanvasClick(event: MouseEvent): void {
    this.onClick.emit(event);

    if (!this.canvasContainer) {
      return;
    }

    const rect = this.canvasContainer.nativeElement.getBoundingClientRect();
    const dataPoint = this.chartService.getDataPointAt(
      event.clientX - rect.left,
      event.clientY - rect.top,
    );

    if (!dataPoint) {
      return;
    }

    this.onDataPointClick.emit({
      dataPoint,
      originalEvent: event,
      chartType: this.chartType,
    });
    this.onSelectionChange.emit({
      selectedPoints: [dataPoint],
      deselectedPoints: [],
      selectionMode: 'single',
      source: 'click',
    });
  }

  handleLegendItemClick(item: ChartLegendItem, legendIndex: number, event: MouseEvent): void {
    event.stopPropagation();

    const next = this.chartService.toggleLegendItem(item.label);
    this.syncLegendItems();
    this.cdr.markForCheck();

    this.onLegendClick.emit({
      legendItem: item.label,
      legendIndex,
      isVisible: next?.isVisible ?? item.isVisible,
      originalEvent: event,
    });
  }

  private initializeChart(): void {
    if (!this.canvasContainer) {
      return;
    }

    this.chartService.initialize(this.canvasContainer.nativeElement, {
      chartType: this.chartType,
      showLegend: this.showLegend,
      legendPosition: this.legendPosition,
      enableZoom: this.enableZoom,
      enableDrillDown: this.enableDrillDown,
      axisScale: this.axisScale,
      numberFormat: this.numberFormat,
      feeds: this.feeds,
      colorPalette: this.colorPalette,
      dataSource: this.dataSource,
    });
    this.syncLegendItems();

    if (this.dataSource) {
      this.refresh();
      return;
    }

    this.cdr.markForCheck();
  }

  private updateChart(): void {
    this.chartService.updateConfig({
      chartType: this.chartType,
      axisScale: this.axisScale,
      numberFormat: this.numberFormat,
      feeds: this.feeds,
      colorPalette: this.colorPalette,
      dataSource: this.dataSource,
    });
    this.syncLegendItems();

    if (this.dataSource) {
      this.refresh();
      return;
    }

    this.cdr.markForCheck();
  }

  private updateLegend(): void {
    this.chartService.updateLegend({
      show: this.showLegend,
      position: this.legendPosition,
    });
    this.syncLegendItems();
    this.cdr.markForCheck();
  }

  private syncLegendItems(): void {
    this.legendItems = this.chartService.getLegendItems();
  }
}
