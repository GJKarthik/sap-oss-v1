/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Chart, ChartType, Feed, Forecast, AxisScale, RankOptions
 *
 * Maps to: sac_widgets.mg category "Visualization" (Chart-related)
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/chart/ (13 handlers)
 */

import type { OperationResult, ChartLegendPosition } from '../types';
import { type ChartType, type Feed, type ForecastType, type RankDirection } from '../types';
import type { SACRestAPIClient } from '../client';
import { Widget } from '../widgets';

// ---------------------------------------------------------------------------
// Chart sub-types
// ---------------------------------------------------------------------------

export interface ChartAxisScale {
  min?: number;
  max?: number;
  type?: string;
  autoScale?: boolean;
}

export interface ChartAxisScaleEffective {
  effectiveMin: number;
  effectiveMax: number;
  effectiveType?: string;
}

export interface ChartNumberFormat {
  pattern?: string;
  decimalPlaces?: number;
  scaling?: number;
}

export interface ChartQuickActionsVisibility {
  filterVisible?: boolean;
  sortVisible?: boolean;
  rankVisible?: boolean;
  drillVisible?: boolean;
}

export interface ChartRankOptions {
  measure?: string;
  count?: number;
  direction?: RankDirection;
  enabled?: boolean;
}

export interface ChartSortOptions {
  dimensionId: string;
  ascending: boolean;
}

export interface ChartLegendConfig {
  visible: boolean;
  position?: 'top' | 'bottom' | 'left' | 'right';
}

export interface ForecastConfig {
  algorithm?: ForecastType;
  periods?: number;
  confidenceLevel?: number;
}

export interface ForecastResult {
  values: number[];
  lowerBound?: number[];
  upperBound?: number[];
  algorithm: ForecastType;
}

export interface SmartGroupingConfig {
  enabled: boolean;
  threshold?: number;
  othersLabel?: string;
}

export interface FeedConfig {
  feedType: Feed;
  dimensions?: string[];
  measures?: string[];
}

export interface DataChangeInsight {
  hasChanges: boolean;
  changeCount: number;
  summary?: string;
  contributors?: Array<{ dimension: string; member: string; contribution: number }>;
}

// ---------------------------------------------------------------------------
// Chart class
// ---------------------------------------------------------------------------

export class Chart extends Widget {
  // -- Data source -----------------------------------------------------------

  async getDataSource(): Promise<string> {
    return this.client.get<string>(`/chart/${e(this.id)}/datasource`);
  }

  async setDataSource(dsName: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/datasource`, { name: dsName });
  }

  // -- Chart type ------------------------------------------------------------

  async getChartType(): Promise<ChartType> {
    return this.client.get<ChartType>(`/chart/${e(this.id)}/type`);
  }

  async setChartType(chartType: ChartType): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/type`, { chartType });
  }

  // -- Selection -------------------------------------------------------------

  async getSelection(): Promise<unknown> {
    return this.client.get(`/chart/${e(this.id)}/selection`);
  }

  async setSelection(selection: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/selection`, selection);
  }

  async getSelections(): Promise<unknown[]> {
    return this.client.get<unknown[]>(`/chart/${e(this.id)}/selections`);
  }

  async clearSelections(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/selections`);
  }

  // -- Feed management -------------------------------------------------------

  async addDimension(feedType: Feed, dimensionId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/feed/dimension`, { feedType, dimensionId });
  }

  async removeDimension(dimensionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/feed/dimension/${e(dimensionId)}`);
  }

  async addMember(feedType: Feed, memberId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/feed/member`, { feedType, memberId });
  }

  async removeMember(feedType: Feed, memberId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/feed/${e(feedType)}/member/${e(memberId)}`);
  }

  // -- Filter ----------------------------------------------------------------

  async setDimensionFilter(dimensionId: string, memberIds: string[]): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/filter`, { dimensionId, memberIds });
  }

  async removeDimensionFilter(dimensionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/filter/${e(dimensionId)}`);
  }

  async getDimensionFilter(dimensionId: string): Promise<string[]> {
    return this.client.get<string[]>(`/chart/${e(this.id)}/filter/${e(dimensionId)}`);
  }

  async getMembers(feed: Feed): Promise<Array<{ id: string; description?: string }>> {
    return this.client.get(`/chart/${e(this.id)}/feed/${e(feed)}/members`);
  }

  // -- Sort & Rank -----------------------------------------------------------

  async setSort(options: ChartSortOptions): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/sort`, options);
  }

  async removeSort(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/sort`);
  }

  async getRankOptions(): Promise<ChartRankOptions> {
    return this.client.get<ChartRankOptions>(`/chart/${e(this.id)}/rank`);
  }

  async setRankOptions(options: ChartRankOptions): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/rank`, options);
  }

  async removeRank(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/rank`);
  }

  // -- Axis scale ------------------------------------------------------------

  async getAxisScale(axis: string): Promise<ChartAxisScale> {
    return this.client.get<ChartAxisScale>(`/chart/${e(this.id)}/axis/${e(axis)}/scale`);
  }

  async setAxisScale(axis: string, scale: ChartAxisScale): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/axis/${e(axis)}/scale`, scale);
  }

  async getAxisScaleEffective(axis: string): Promise<ChartAxisScaleEffective> {
    return this.client.get<ChartAxisScaleEffective>(`/chart/${e(this.id)}/axis/${e(axis)}/scaleEffective`);
  }

  // -- Number format ---------------------------------------------------------

  async getNumberFormat(): Promise<ChartNumberFormat> {
    return this.client.get<ChartNumberFormat>(`/chart/${e(this.id)}/numberFormat`);
  }

  async setNumberFormat(fmt: ChartNumberFormat): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/numberFormat`, fmt);
  }

  // -- Quick actions ---------------------------------------------------------

  async getQuickActionsVisibility(): Promise<ChartQuickActionsVisibility> {
    return this.client.get<ChartQuickActionsVisibility>(`/chart/${e(this.id)}/quickActions`);
  }

  async setQuickActionsVisibility(vis: ChartQuickActionsVisibility): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/quickActions`, vis);
  }

  // -- Legend ----------------------------------------------------------------

  async showLegend(): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/legend`, { visible: true });
  }

  async hideLegend(): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/legend`, { visible: false });
  }

  async isLegendVisible(): Promise<boolean> {
    return this.client.get<boolean>(`/chart/${e(this.id)}/legend/visible`);
  }

  async setLegendPosition(position: ChartLegendPosition): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/legend/position`, { position });
  }

  // -- Title ----------------------------------------------------------------

  async getTitle(): Promise<string> {
    return this.client.get<string>(`/chart/${e(this.id)}/title`);
  }

  async setTitle(title: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/title`, { title });
  }

  async setSubtitle(subtitle: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/subtitle`, { subtitle });
  }

  // -- Color palette ---------------------------------------------------------

  async getColorPalette(): Promise<string[]> {
    return this.client.get<string[]>(`/chart/${e(this.id)}/colorPalette`);
  }

  async setColorPalette(colors: string[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/colorPalette`, { colors });
  }

  // -- Zoom -----------------------------------------------------------------

  async zoom(factor: number): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/zoom`, { factor });
  }

  async resetZoom(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/zoom/reset`);
  }

  // -- Data insights ---------------------------------------------------------

  async getDataChangeInsights(): Promise<DataChangeInsight> {
    return this.client.get<DataChangeInsight>(`/chart/${e(this.id)}/insights`);
  }

  // -- Smart grouping --------------------------------------------------------

  async setSmartGrouping(config: SmartGroupingConfig): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/chart/${e(this.id)}/smartGrouping`, config);
  }

  // -- Forecast --------------------------------------------------------------

  async addForecast(config: ForecastConfig): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/forecast`, config);
  }

  async removeForecast(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/chart/${e(this.id)}/forecast`);
  }

  async getForecastResults(): Promise<ForecastResult> {
    return this.client.get<ForecastResult>(`/chart/${e(this.id)}/forecast/results`);
  }

  // -- Export ----------------------------------------------------------------

  async exportToPdf(): Promise<Blob> {
    return this.client.post<Blob>(`/chart/${e(this.id)}/export/pdf`);
  }

  async exportToPng(): Promise<Blob> {
    return this.client.post<Blob>(`/chart/${e(this.id)}/export/png`);
  }

  async exportToExcel(): Promise<Blob> {
    return this.client.post<Blob>(`/chart/${e(this.id)}/export/excel`);
  }

  // -- Navigation panel -------------------------------------------------------

  async openNavigationPanel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/navigationPanel/open`);
  }

  async closeNavigationPanel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/navigationPanel/close`);
  }

  // -- Refresh ---------------------------------------------------------------

  async refresh(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/chart/${e(this.id)}/refresh`);
  }

  // -- Factory ---------------------------------------------------------------

  static async getChart(client: SACRestAPIClient, widgetId: string): Promise<Chart> {
    return new Chart(client, widgetId);
  }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface ChartEvents {
  select: (selection: unknown) => void;
  dataChanged: (insights: DataChangeInsight) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

export type { ChartType, Feed, ForecastType } from '../types';
