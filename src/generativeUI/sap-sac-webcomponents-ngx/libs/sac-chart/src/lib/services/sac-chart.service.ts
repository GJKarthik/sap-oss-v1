/**
 * SAC Chart Service
 *
 * Service for managing SAC chart rendering and data operations.
 * Derived from mangle/sac_widget.mg service_class derivation.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import { ChartType, Feed } from '@sap-oss/sac-ngx-core';
import type {
  ChartConfig,
  ChartLegendConfig,
  ChartLegendItem,
  ChartResultSetLike,
  DataPoint,
} from '../types/chart.types';

type ChartHitTarget =
  | {
      kind: 'rect';
      x: number;
      y: number;
      width: number;
      height: number;
      dataPoint: DataPoint;
    }
  | {
      kind: 'circle';
      cx: number;
      cy: number;
      radius: number;
      dataPoint: DataPoint;
    }
  | {
      kind: 'arc';
      cx: number;
      cy: number;
      innerRadius: number;
      outerRadius: number;
      startAngle: number;
      endAngle: number;
      dataPoint: DataPoint;
    };

interface ChartRecord {
  category: string;
  series: string;
  measure: string;
  value: number;
  formattedValue: string;
}

interface NormalizedChartData {
  primaryDimension: string;
  categories: string[];
  series: string[];
  records: ChartRecord[];
}

const DEFAULT_COLORS = [
  '#0a6ed1',
  '#f58b00',
  '#198038',
  '#e76500',
  '#8f3a96',
  '#c62828',
  '#0070f2',
  '#6a6d70',
];

const SVG_NS = 'http://www.w3.org/2000/svg';

@Injectable()
export class SacChartService {
  private containerElement: HTMLElement | null = null;
  private config: Partial<ChartConfig> = {};
  private legendItems: ChartLegendItem[] = [];
  private chartData: NormalizedChartData | null = null;
  private currentSvg = '';
  private hitTargets: ChartHitTarget[] = [];
  private hiddenLegendItems = new Set<string>();

  private readonly loading$ = new BehaviorSubject<boolean>(false);
  private readonly error$ = new BehaviorSubject<Error | null>(null);

  get isLoading$(): Observable<boolean> {
    return this.loading$.asObservable();
  }

  get lastError$(): Observable<Error | null> {
    return this.error$.asObservable();
  }

  initialize(container: HTMLElement, config: Partial<ChartConfig>): void {
    this.containerElement = container;
    this.config = { ...config };
    this.renderChart();
  }

  updateConfig(config: Partial<ChartConfig>): void {
    const previousDataSource = this.config.dataSource;
    this.config = { ...this.config, ...config };

    if (config.dataSource && config.dataSource !== previousDataSource) {
      this.chartData = null;
      this.hiddenLegendItems.clear();
    }

    this.renderChart();
  }

  updateLegend(legendConfig: ChartLegendConfig): void {
    this.config = {
      ...this.config,
      showLegend: legendConfig.show,
      legendPosition: legendConfig.position,
    };
  }

  async refreshData(): Promise<void> {
    this.loading$.next(true);
    this.error$.next(null);

    try {
      const dataSource = this.config.dataSource;
      if (!dataSource || typeof dataSource.getData !== 'function') {
        this.chartData = null;
        this.renderEmptyState('Configure a datasource to render the chart.');
        throw new Error('Chart dataSource must provide an async getData() method');
      }

      const resultSet = await dataSource.getData();
      this.chartData = this.normalizeResultSet(resultSet);
      this.hiddenLegendItems = new Set(
        Array.from(this.hiddenLegendItems).filter((label) => this.hasLegendItem(label)),
      );
      this.renderChart();
    } catch (err) {
      const error = err instanceof Error ? err : new Error('Failed to load chart data');
      this.error$.next(error);
      throw error;
    } finally {
      this.loading$.next(false);
    }
  }

  async exportChart(format: 'png' | 'svg'): Promise<Blob> {
    if (!this.currentSvg) {
      throw new Error('Chart not initialized');
    }

    if (format === 'svg') {
      return new Blob([this.currentSvg], { type: 'image/svg+xml' });
    }

    return this.exportPng();
  }

  getDataPointAt(x: number, y: number): DataPoint | null {
    for (const target of this.hitTargets) {
      if (target.kind === 'rect') {
        const withinX = x >= target.x && x <= target.x + target.width;
        const withinY = y >= target.y && y <= target.y + target.height;
        if (withinX && withinY) {
          return target.dataPoint;
        }
        continue;
      }

      if (target.kind === 'circle') {
        const distance = Math.hypot(x - target.cx, y - target.cy);
        if (distance <= target.radius) {
          return target.dataPoint;
        }
        continue;
      }

      const dx = x - target.cx;
      const dy = y - target.cy;
      const distance = Math.hypot(dx, dy);
      if (distance < target.innerRadius || distance > target.outerRadius) {
        continue;
      }

      const angle = this.normaliseAngle(Math.atan2(dy, dx));
      const withinArc = target.startAngle <= target.endAngle
        ? angle >= target.startAngle && angle <= target.endAngle
        : angle >= target.startAngle || angle <= target.endAngle;
      if (withinArc) {
        return target.dataPoint;
      }
    }

    return null;
  }

  getLegendItems(): ChartLegendItem[] {
    return [...this.legendItems];
  }

  toggleLegendItem(label: string): ChartLegendItem | null {
    if (!this.hasLegendItem(label)) {
      return null;
    }

    if (this.hiddenLegendItems.has(label)) {
      this.hiddenLegendItems.delete(label);
    } else {
      this.hiddenLegendItems.add(label);
    }

    this.renderChart();
    return this.legendItems.find((item) => item.label === label) ?? null;
  }

  destroyChart(): void {
    if (this.containerElement) {
      this.containerElement.innerHTML = '';
    }

    this.containerElement = null;
    this.chartData = null;
    this.currentSvg = '';
    this.hitTargets = [];
    this.legendItems = [];
    this.hiddenLegendItems.clear();
    this.loading$.complete();
    this.error$.complete();
  }

  private renderChart(): void {
    if (!this.containerElement) {
      return;
    }

    if (!this.chartData) {
      this.legendItems = [];
      this.hitTargets = [];
      this.currentSvg = '';
      this.renderEmptyState('Waiting for chart data.');
      return;
    }

    const chartType = this.config.chartType ?? ChartType.Bar;
    const visibleData = this.filterVisibleData(this.chartData, chartType);
    if (visibleData.records.length === 0) {
      this.currentSvg = '';
      this.hitTargets = [];
      this.legendItems = this.buildLegendItems(this.chartData, chartType);
      this.renderEmptyState('All chart series are hidden.');
      return;
    }

    const size = this.resolveCanvasSize();
    const rendered = this.isPolarChart(chartType)
      ? this.renderPolarChart(visibleData, chartType, size.width, size.height)
      : this.renderCartesianChart(visibleData, chartType, size.width, size.height);

    this.legendItems = rendered.legendItems;
    this.hitTargets = rendered.hitTargets;
    this.currentSvg = rendered.svg;
    this.containerElement.innerHTML = rendered.svg;
  }

  private renderEmptyState(message: string): void {
    if (!this.containerElement) {
      return;
    }

    this.containerElement.innerHTML = `
      <div class="sac-chart__empty-state">
        <span>${this.escapeHtml(message)}</span>
      </div>
    `;
  }

  private renderCartesianChart(
    data: NormalizedChartData,
    chartType: ChartType,
    width: number,
    height: number,
  ): { svg: string; hitTargets: ChartHitTarget[]; legendItems: ChartLegendItem[] } {
    const legendItems = this.buildLegendItems(data, chartType);
    const visibleSeries = legendItems.filter((item) => item.isVisible).map((item) => item.label);
    const seriesMap = new Map<string, string>();
    legendItems.forEach((item) => seriesMap.set(item.label, item.color));

    const categories = data.categories;
    const records = data.records;
    const values = records.map((record) => record.value);
    const scale = this.resolveValueScale(values);

    const margins = { top: 18, right: 18, bottom: 62, left: 56 };
    const plotWidth = Math.max(120, width - margins.left - margins.right);
    const plotHeight = Math.max(100, height - margins.top - margins.bottom);

    const gridLines: string[] = [];
    const labels: string[] = [];
    const hitTargets: ChartHitTarget[] = [];

    if (this.isHorizontalChart(chartType)) {
      const baselineX = this.scaleValue(0, scale.min, scale.max, margins.left, margins.left + plotWidth);
      const groupHeight = plotHeight / Math.max(1, categories.length);
      const barGap = Math.min(12, groupHeight * 0.2);
      const barHeight = Math.max(
        12,
        (groupHeight - barGap * 2) / Math.max(1, visibleSeries.length),
      );

      for (const tick of this.buildTicks(scale.min, scale.max)) {
        const x = this.scaleValue(tick, scale.min, scale.max, margins.left, margins.left + plotWidth);
        gridLines.push(
          `<line x1="${x}" y1="${margins.top}" x2="${x}" y2="${margins.top + plotHeight}" stroke="#d9d9d9" stroke-dasharray="4 4" />`,
        );
        labels.push(
          `<text x="${x}" y="${height - 16}" text-anchor="middle" fill="#6a6d70" font-size="11">${this.escapeHtml(this.formatNumeric(tick))}</text>`,
        );
      }

      categories.forEach((category, categoryIndex) => {
        const yBase = margins.top + categoryIndex * groupHeight + barGap;
        labels.push(
          `<text x="${margins.left - 8}" y="${yBase + groupHeight / 2}" text-anchor="end" dominant-baseline="middle" fill="#32363a" font-size="12">${this.escapeHtml(category)}</text>`,
        );

        visibleSeries.forEach((seriesLabel, seriesIndex) => {
          const record = records.find((candidate) =>
            candidate.category === category && candidate.series === seriesLabel,
          );
          if (!record) {
            return;
          }

          const valueX = this.scaleValue(
            record.value,
            scale.min,
            scale.max,
            margins.left,
            margins.left + plotWidth,
          );
          const x = Math.min(baselineX, valueX);
          const y = yBase + seriesIndex * barHeight;
          const rectWidth = Math.max(2, Math.abs(valueX - baselineX));
          const color = seriesMap.get(seriesLabel) ?? DEFAULT_COLORS[0];

          hitTargets.push({
            kind: 'rect',
            x,
            y,
            width: rectWidth,
            height: barHeight - 4,
            dataPoint: {
              dimension: data.primaryDimension,
              member: category,
              measure: record.measure,
              value: record.value,
              formattedValue: record.formattedValue,
              coordinates: {
                x: x + rectWidth,
                y: y + (barHeight - 4) / 2,
              },
            },
          });
        });
      });
    } else {
      const baselineY = this.scaleValue(0, scale.min, scale.max, margins.top + plotHeight, margins.top);
      const groupWidth = plotWidth / Math.max(1, categories.length);
      const barGap = Math.min(16, groupWidth * 0.16);
      const barWidth = Math.max(
        10,
        (groupWidth - barGap * 2) / Math.max(1, visibleSeries.length),
      );

      for (const tick of this.buildTicks(scale.min, scale.max)) {
        const y = this.scaleValue(tick, scale.min, scale.max, margins.top + plotHeight, margins.top);
        gridLines.push(
          `<line x1="${margins.left}" y1="${y}" x2="${margins.left + plotWidth}" y2="${y}" stroke="#d9d9d9" stroke-dasharray="4 4" />`,
        );
        labels.push(
          `<text x="${margins.left - 8}" y="${y + 4}" text-anchor="end" fill="#6a6d70" font-size="11">${this.escapeHtml(this.formatNumeric(tick))}</text>`,
        );
      }

      categories.forEach((category, categoryIndex) => {
        const xBase = margins.left + categoryIndex * groupWidth + barGap;
        labels.push(
          `<text x="${xBase + groupWidth / 2}" y="${height - 18}" text-anchor="middle" fill="#32363a" font-size="12">${this.escapeHtml(category)}</text>`,
        );

        visibleSeries.forEach((seriesLabel, seriesIndex) => {
          const record = records.find((candidate) =>
            candidate.category === category && candidate.series === seriesLabel,
          );
          if (!record) {
            return;
          }

          const valueY = this.scaleValue(
            record.value,
            scale.min,
            scale.max,
            margins.top + plotHeight,
            margins.top,
          );
          const x = xBase + seriesIndex * barWidth;
          const y = Math.min(baselineY, valueY);
          const rectHeight = Math.max(2, Math.abs(baselineY - valueY));
          const color = seriesMap.get(seriesLabel) ?? DEFAULT_COLORS[0];
          const dataPoint: DataPoint = {
            dimension: data.primaryDimension,
            member: category,
            measure: record.measure,
            value: record.value,
            formattedValue: record.formattedValue,
            coordinates: {
              x: x + barWidth / 2,
              y,
            },
          };

          if (this.isLineChart(chartType)) {
            hitTargets.push({
              kind: 'circle',
              cx: xBase + groupWidth / 2,
              cy: valueY,
              radius: 10,
              dataPoint,
            });
            return;
          }

          hitTargets.push({
            kind: 'rect',
            x,
            y,
            width: Math.max(6, barWidth - 4),
            height: rectHeight,
            dataPoint,
          });
        });
      });
    }

    const seriesGroups = visibleSeries.map((seriesLabel, seriesIndex) => {
      const color = seriesMap.get(seriesLabel) ?? DEFAULT_COLORS[seriesIndex % DEFAULT_COLORS.length];
      const seriesRecords = categories
        .map((category) => records.find((record) => record.category === category && record.series === seriesLabel))
        .filter((record): record is ChartRecord => Boolean(record));

      if (this.isLineChart(chartType)) {
        const points = seriesRecords.map((record) => {
          const categoryIndex = categories.indexOf(record.category);
          const groupWidth = plotWidth / Math.max(1, categories.length);
          const x = margins.left + categoryIndex * groupWidth + groupWidth / 2;
          const y = this.scaleValue(
            record.value,
            scale.min,
            scale.max,
            margins.top + plotHeight,
            margins.top,
          );
          return `${x},${y}`;
        });

        const polyline = `<polyline fill="none" stroke="${color}" stroke-width="3" points="${points.join(' ')}" />`;
        if (chartType !== ChartType.Area || points.length === 0) {
          return polyline;
        }

        const areaPoints = [
          points[0]?.split(',')[0] ? `${points[0].split(',')[0]},${margins.top + plotHeight}` : '',
          ...points,
          points[points.length - 1]?.split(',')[0]
            ? `${points[points.length - 1].split(',')[0]},${margins.top + plotHeight}`
            : '',
        ].filter(Boolean);

        return `
          <polygon fill="${color}" fill-opacity="0.18" points="${areaPoints.join(' ')}" />
          ${polyline}
        `;
      }

      return seriesRecords.map((record) => {
        const categoryIndex = categories.indexOf(record.category);
        if (this.isHorizontalChart(chartType)) {
          const groupHeight = plotHeight / Math.max(1, categories.length);
          const barGap = Math.min(12, groupHeight * 0.2);
          const barHeight = Math.max(
            12,
            (groupHeight - barGap * 2) / Math.max(1, visibleSeries.length),
          );
          const y = margins.top + categoryIndex * groupHeight + barGap + seriesIndex * barHeight;
          const baselineX = this.scaleValue(0, scale.min, scale.max, margins.left, margins.left + plotWidth);
          const valueX = this.scaleValue(
            record.value,
            scale.min,
            scale.max,
            margins.left,
            margins.left + plotWidth,
          );
          const x = Math.min(baselineX, valueX);
          const rectWidth = Math.max(2, Math.abs(valueX - baselineX));

          return `<rect x="${x}" y="${y}" width="${rectWidth}" height="${Math.max(6, barHeight - 4)}" rx="4" fill="${color}" />`;
        }

        const groupWidth = plotWidth / Math.max(1, categories.length);
        const barGap = Math.min(16, groupWidth * 0.16);
        const barWidth = Math.max(
          10,
          (groupWidth - barGap * 2) / Math.max(1, visibleSeries.length),
        );
        const x = margins.left + categoryIndex * groupWidth + barGap + seriesIndex * barWidth;
        const baselineY = this.scaleValue(0, scale.min, scale.max, margins.top + plotHeight, margins.top);
        const valueY = this.scaleValue(
          record.value,
          scale.min,
          scale.max,
          margins.top + plotHeight,
          margins.top,
        );
        const y = Math.min(baselineY, valueY);
        const rectHeight = Math.max(2, Math.abs(baselineY - valueY));

        return `<rect x="${x}" y="${y}" width="${Math.max(6, barWidth - 4)}" height="${rectHeight}" rx="4" fill="${color}" />`;
      }).join('');
    });

    return {
      svg: `
        <svg xmlns="${SVG_NS}" viewBox="0 0 ${width} ${height}" class="sac-chart__svg" role="img" aria-label="SAC chart">
          <rect x="0" y="0" width="${width}" height="${height}" fill="#ffffff" />
          ${gridLines.join('')}
          <line x1="${margins.left}" y1="${margins.top + plotHeight}" x2="${margins.left + plotWidth}" y2="${margins.top + plotHeight}" stroke="#89919a" />
          <line x1="${margins.left}" y1="${margins.top}" x2="${margins.left}" y2="${margins.top + plotHeight}" stroke="#89919a" />
          ${seriesGroups.join('')}
          ${this.renderCartesianDataLabels(hitTargets)}
          ${labels.join('')}
        </svg>
      `,
      hitTargets,
      legendItems,
    };
  }

  private renderPolarChart(
    data: NormalizedChartData,
    chartType: ChartType,
    width: number,
    height: number,
  ): { svg: string; hitTargets: ChartHitTarget[]; legendItems: ChartLegendItem[] } {
    const legendItems = data.categories.map((category, index) => ({
      label: category,
      color: this.resolveColor(index),
      isVisible: !this.hiddenLegendItems.has(category),
    }));
    const aggregatedByCategory = new Map<string, number>();
    const formattedByCategory = new Map<string, string>();

    for (const record of data.records) {
      if (this.hiddenLegendItems.has(record.category)) {
        continue;
      }

      aggregatedByCategory.set(record.category, (aggregatedByCategory.get(record.category) ?? 0) + record.value);
      formattedByCategory.set(record.category, record.formattedValue);
    }

    const categories = Array.from(aggregatedByCategory.keys());

    if (categories.length === 0) {
      return {
        svg: `
          <svg xmlns="${SVG_NS}" viewBox="0 0 ${width} ${height}" class="sac-chart__svg" role="img" aria-label="SAC chart">
            <text x="${width / 2}" y="${height / 2}" text-anchor="middle" fill="#6a6d70" font-size="14">No chart data available</text>
          </svg>
        `,
        hitTargets: [],
        legendItems,
      };
    }

    const values = categories.map((category) => aggregatedByCategory.get(category) ?? 0);
    const total = values.reduce((sum, value) => sum + Math.max(value, 0), 0);
    const cx = width / 2;
    const cy = height / 2;
    const outerRadius = Math.max(70, Math.min(width, height) / 2 - 20);
    const innerRadius = chartType === ChartType.Donut ? outerRadius * 0.58 : 0;
    let startAngle = -Math.PI / 2;

    const slices: string[] = [];
    const hitTargets: ChartHitTarget[] = [];

    categories.forEach((category, index) => {
      const value = aggregatedByCategory.get(category) ?? 0;
      const fraction = total === 0 ? 1 / categories.length : Math.max(value, 0) / total;
      const endAngle = startAngle + fraction * Math.PI * 2;
      const color = this.resolveColor(index);
      const path = this.describeArc(cx, cy, innerRadius, outerRadius, startAngle, endAngle);
      const midAngle = startAngle + (endAngle - startAngle) / 2;
      const labelRadius = innerRadius > 0 ? (innerRadius + outerRadius) / 2 : outerRadius * 0.72;
      const labelX = cx + Math.cos(midAngle) * labelRadius;
      const labelY = cy + Math.sin(midAngle) * labelRadius;
      const formattedValue = formattedByCategory.get(category) ?? this.formatNumeric(value);

      slices.push(`
        <path d="${path}" fill="${color}" stroke="#ffffff" stroke-width="2" />
        <text x="${labelX}" y="${labelY}" text-anchor="middle" dominant-baseline="middle" fill="#ffffff" font-size="12" font-weight="600">
          ${this.escapeHtml(this.compactLabel(category))}
        </text>
      `);

      hitTargets.push({
        kind: 'arc',
        cx,
        cy,
        innerRadius,
        outerRadius,
        startAngle: this.normaliseAngle(startAngle),
        endAngle: this.normaliseAngle(endAngle < startAngle ? endAngle + Math.PI * 2 : endAngle),
        dataPoint: {
          dimension: data.primaryDimension,
          member: category,
          measure: data.records[0]?.measure ?? 'Value',
          value,
          formattedValue,
          coordinates: {
            x: labelX,
            y: labelY,
          },
        },
      });

      startAngle = endAngle;
    });

    return {
      svg: `
        <svg xmlns="${SVG_NS}" viewBox="0 0 ${width} ${height}" class="sac-chart__svg" role="img" aria-label="SAC chart">
          <rect x="0" y="0" width="${width}" height="${height}" fill="#ffffff" />
          ${slices.join('')}
        </svg>
      `,
      hitTargets,
      legendItems,
    };
  }

  private renderCartesianDataLabels(hitTargets: ChartHitTarget[]): string {
    return hitTargets.map((target) => {
      const point = target.dataPoint;
      const x = point.coordinates?.x ?? 0;
      const y = point.coordinates?.y ?? 0;

      return `
        <text x="${x}" y="${Math.max(16, y - 6)}" text-anchor="middle" fill="#32363a" font-size="11">
          ${this.escapeHtml(point.formattedValue)}
        </text>
      `;
    }).join('');
  }

  private normalizeResultSet(resultSet: ChartResultSetLike): NormalizedChartData {
    const rows = Array.isArray(resultSet.data) ? resultSet.data : [];
    const dimensionIds = Array.isArray(resultSet.dimensions) ? resultSet.dimensions : [];
    const measureIds = Array.isArray(resultSet.measures) ? resultSet.measures : [];
    const categoryDimensions = this.resolveDimensionFeed(Feed.CategoryAxis, dimensionIds);
    const seriesDimensions = this.resolveDimensionFeed(Feed.Color, dimensionIds)
      .filter((dimension) => !categoryDimensions.includes(dimension));
    const selectedMeasures = this.resolveMeasureFeed(measureIds);
    const aggregated = new Map<string, ChartRecord>();
    const categories: string[] = [];
    const series: string[] = [];

    rows.forEach((row, rowIndex) => {
      const category = this.composeLabel(
        categoryDimensions.map((dimension) => this.getCellLabel(row, dimensionIds.indexOf(dimension))),
      ) || `Row ${rowIndex + 1}`;
      const seriesDimensionLabel = this.composeLabel(
        seriesDimensions.map((dimension) => this.getCellLabel(row, dimensionIds.indexOf(dimension))),
      );

      if (!categories.includes(category)) {
        categories.push(category);
      }

      selectedMeasures.forEach((measureId) => {
        const measureIndex = measureIds.indexOf(measureId);
        if (measureIndex === -1) {
          return;
        }

        const cell = row[dimensionIds.length + measureIndex];
        const numericValue = this.getNumericCellValue(cell);
        if (numericValue == null) {
          return;
        }

        const seriesLabel = this.resolveSeriesLabel(seriesDimensionLabel, measureId, selectedMeasures.length);
        if (!series.includes(seriesLabel)) {
          series.push(seriesLabel);
        }

        const key = `${category}::${seriesLabel}::${measureId}`;
        const existing = aggregated.get(key);
        const value = (existing?.value ?? 0) + numericValue;
        aggregated.set(key, {
          category,
          series: seriesLabel,
          measure: measureId,
          value,
          formattedValue: this.formatNumeric(value),
        });
      });
    });

    const records = Array.from(aggregated.values());
    return {
      primaryDimension: categoryDimensions[0] ?? dimensionIds[0] ?? 'Dimension',
      categories,
      series,
      records,
    };
  }

  private filterVisibleData(data: NormalizedChartData, chartType: ChartType): NormalizedChartData {
    if (this.isPolarChart(chartType)) {
      return {
        ...data,
        records: data.records.filter((record) => !this.hiddenLegendItems.has(record.category)),
      };
    }

    return {
      ...data,
      records: data.records.filter((record) => !this.hiddenLegendItems.has(record.series)),
    };
  }

  private buildLegendItems(data: NormalizedChartData, chartType: ChartType): ChartLegendItem[] {
    if (this.isPolarChart(chartType)) {
      return data.categories.map((category, index) => ({
        label: category,
        color: this.resolveColor(index),
        isVisible: !this.hiddenLegendItems.has(category),
      }));
    }

    return data.series.map((seriesLabel, index) => ({
      label: seriesLabel,
      color: this.resolveColor(index),
      isVisible: !this.hiddenLegendItems.has(seriesLabel),
    }));
  }

  private hasLegendItem(label: string): boolean {
    return this.legendItems.some((item) => item.label === label)
      || this.chartData?.series.includes(label)
      || this.chartData?.categories.includes(label)
      || false;
  }

  private resolveCanvasSize(): { width: number; height: number } {
    return {
      width: Math.max(320, this.containerElement?.clientWidth || 640),
      height: Math.max(220, this.containerElement?.clientHeight || 360),
    };
  }

  private resolveDimensionFeed(feed: Feed, availableDimensions: string[]): string[] {
    const configured = this.config.feeds?.get(feed) ?? [];
    const filtered = configured.filter((dimension) => availableDimensions.includes(dimension));

    if (filtered.length > 0) {
      return filtered;
    }

    return feed === Feed.CategoryAxis && availableDimensions.length > 0
      ? [availableDimensions[0]]
      : [];
  }

  private resolveMeasureFeed(availableMeasures: string[]): string[] {
    const configured = this.config.feeds?.get(Feed.ValueAxis) ?? [];
    const filtered = configured.filter((measure) => availableMeasures.includes(measure));

    if (filtered.length > 0) {
      return filtered;
    }

    return availableMeasures.length > 0 ? [availableMeasures[0]] : [];
  }

  private resolveSeriesLabel(seriesDimensionLabel: string, measureId: string, measureCount: number): string {
    if (seriesDimensionLabel && measureCount > 1) {
      return `${seriesDimensionLabel} • ${measureId}`;
    }

    if (seriesDimensionLabel) {
      return seriesDimensionLabel;
    }

    return measureId || 'Value';
  }

  private getCellLabel(row: readonly unknown[], index: number): string {
    const cell = row[index];
    if (cell && typeof cell === 'object' && 'formatted' in (cell as Record<string, unknown>)) {
      const formatted = (cell as { formatted?: unknown }).formatted;
      if (typeof formatted === 'string' && formatted.trim()) {
        return formatted.trim();
      }
    }

    if (cell && typeof cell === 'object' && 'value' in (cell as Record<string, unknown>)) {
      const value = (cell as { value?: unknown }).value;
      return value == null ? '' : String(value);
    }

    return cell == null ? '' : String(cell);
  }

  private getNumericCellValue(cell: unknown): number | null {
    if (cell && typeof cell === 'object' && 'value' in (cell as Record<string, unknown>)) {
      const value = (cell as { value?: unknown }).value;
      if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
      }
      if (typeof value === 'string') {
        return this.parseNumericString(value);
      }
    }

    if (cell && typeof cell === 'object' && 'formatted' in (cell as Record<string, unknown>)) {
      const formatted = (cell as { formatted?: unknown }).formatted;
      if (typeof formatted === 'string') {
        return this.parseNumericString(formatted);
      }
    }

    if (typeof cell === 'number' && Number.isFinite(cell)) {
      return cell;
    }

    if (typeof cell === 'string') {
      return this.parseNumericString(cell);
    }

    return null;
  }

  private parseNumericString(value: string): number | null {
    const numeric = Number(value.replace(/[^0-9.-]/g, ''));
    return Number.isFinite(numeric) ? numeric : null;
  }

  private composeLabel(parts: string[]): string {
    return parts.map((part) => part.trim()).filter(Boolean).join(' / ');
  }

  private resolveValueScale(values: number[]): { min: number; max: number } {
    const explicitMin = this.config.axisScale?.min;
    const explicitMax = this.config.axisScale?.max;

    let min = explicitMin ?? Math.min(0, ...values);
    let max = explicitMax ?? Math.max(0, ...values);

    if (min === max) {
      max = max + 1;
      min = min - 1;
    }

    return { min, max };
  }

  private buildTicks(min: number, max: number): number[] {
    const tickCount = 5;
    const step = (max - min) / (tickCount - 1);

    return Array.from({ length: tickCount }, (_, index) => {
      const raw = min + step * index;
      return Number.isFinite(raw) ? Number(raw.toFixed(2)) : 0;
    });
  }

  private scaleValue(value: number, min: number, max: number, start: number, end: number): number {
    if (max === min) {
      return (start + end) / 2;
    }

    return start + ((value - min) / (max - min)) * (end - start);
  }

  private async exportPng(): Promise<Blob> {
    if (typeof Image === 'undefined' || typeof document === 'undefined' || typeof URL === 'undefined') {
      throw new Error('PNG export is only available in browser environments');
    }

    const { width, height } = this.resolveCanvasSize();
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;

    const context = canvas.getContext('2d');
    if (!context) {
      throw new Error('Canvas export is unavailable in this browser');
    }

    const image = new Image();
    const svgBlob = new Blob([this.currentSvg], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(svgBlob);

    return new Promise((resolve, reject) => {
      image.onload = () => {
        context.clearRect(0, 0, width, height);
        context.drawImage(image, 0, 0, width, height);
        URL.revokeObjectURL(url);
        canvas.toBlob((blob) => {
          if (blob) {
            resolve(blob);
            return;
          }
          reject(new Error('Failed to export chart'));
        }, 'image/png');
      };

      image.onerror = () => {
        URL.revokeObjectURL(url);
        reject(new Error('Failed to render chart image'));
      };

      image.src = url;
    });
  }

  private describeArc(
    cx: number,
    cy: number,
    innerRadius: number,
    outerRadius: number,
    startAngle: number,
    endAngle: number,
  ): string {
    const largeArcFlag = endAngle - startAngle > Math.PI ? 1 : 0;
    const startOuter = this.polarToCartesian(cx, cy, outerRadius, endAngle);
    const endOuter = this.polarToCartesian(cx, cy, outerRadius, startAngle);

    if (innerRadius === 0) {
      return [
        `M ${cx} ${cy}`,
        `L ${startOuter.x} ${startOuter.y}`,
        `A ${outerRadius} ${outerRadius} 0 ${largeArcFlag} 0 ${endOuter.x} ${endOuter.y}`,
        'Z',
      ].join(' ');
    }

    const startInner = this.polarToCartesian(cx, cy, innerRadius, endAngle);
    const endInner = this.polarToCartesian(cx, cy, innerRadius, startAngle);

    return [
      `M ${startOuter.x} ${startOuter.y}`,
      `A ${outerRadius} ${outerRadius} 0 ${largeArcFlag} 0 ${endOuter.x} ${endOuter.y}`,
      `L ${endInner.x} ${endInner.y}`,
      `A ${innerRadius} ${innerRadius} 0 ${largeArcFlag} 1 ${startInner.x} ${startInner.y}`,
      'Z',
    ].join(' ');
  }

  private polarToCartesian(cx: number, cy: number, radius: number, angle: number): { x: number; y: number } {
    return {
      x: cx + Math.cos(angle) * radius,
      y: cy + Math.sin(angle) * radius,
    };
  }

  private normaliseAngle(angle: number): number {
    const twoPi = Math.PI * 2;
    let next = angle % twoPi;

    if (next < 0) {
      next += twoPi;
    }

    return next;
  }

  private isPolarChart(chartType: ChartType): boolean {
    return chartType === ChartType.Pie || chartType === ChartType.Donut;
  }

  private isLineChart(chartType: ChartType): boolean {
    return chartType === ChartType.Line || chartType === ChartType.Area;
  }

  private isHorizontalChart(chartType: ChartType): boolean {
    return chartType === ChartType.Bar || chartType === ChartType.StackedBar;
  }

  private resolveColor(index: number): string {
    const palette = this.config.colorPalette?.length ? this.config.colorPalette : DEFAULT_COLORS;
    return palette[index % palette.length];
  }

  private formatNumeric(value: number): string {
    const scaleFactor = this.config.numberFormat?.scaleFactor ?? 1;
    const decimalPlaces = this.config.numberFormat?.decimalPlaces ?? 0;
    const formatted = new Intl.NumberFormat('en-US', {
      minimumFractionDigits: decimalPlaces,
      maximumFractionDigits: decimalPlaces,
      useGrouping: this.config.numberFormat?.useGrouping ?? true,
    }).format(value / scaleFactor);

    return `${this.config.numberFormat?.prefix ?? ''}${formatted}${this.config.numberFormat?.suffix ?? ''}`.trim();
  }

  private compactLabel(label: string): string {
    return label.length > 14 ? `${label.slice(0, 11)}…` : label;
  }

  private escapeHtml(value: string): string {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
}
