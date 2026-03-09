/**
 * @sap-oss/sac-webcomponents-ngx/sdk — SmartDiscovery, Forecast, Export, MultiAction,
 *   LinkedAnalysis, DataBindings, Simulation, Alert, Bookmarks, PageState
 *
 * Maps to: sac_widgets.mg categories "Advanced", "State", "Collaboration", "Display", "Style"
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/standard/ + chart/
 */

import type { SACRestAPIClient } from '../client';
import type { OperationResult } from '../types';
import { Widget } from '../widgets';

// ---------------------------------------------------------------------------
// SmartDiscovery
// ---------------------------------------------------------------------------

export interface SmartDiscoveryInsight {
  type: string;
  description: string;
  confidence?: number;
  relatedDimensions?: string[];
  relatedMeasures?: string[];
}

export class SmartDiscovery {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async analyze(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/smartdiscovery/${e(this.id)}/analyze`);
  }

  async getInsights(): Promise<SmartDiscoveryInsight[]> {
    return this.client.get<SmartDiscoveryInsight[]>(`/smartdiscovery/${e(this.id)}/insights`);
  }

  async getKeyInfluencers(): Promise<Array<{ dimension: string; measure: string; influence: number }>> {
    return this.client.get(`/smartdiscovery/${e(this.id)}/keyInfluencers`);
  }

  async getCorrelations(): Promise<Array<{ measure1: string; measure2: string; correlation: number }>> {
    return this.client.get(`/smartdiscovery/${e(this.id)}/correlations`);
  }

  async getOutliers(): Promise<Array<{ dimension: string; member: string; deviation: number }>> {
    return this.client.get(`/smartdiscovery/${e(this.id)}/outliers`);
  }
}

// ---------------------------------------------------------------------------
// Forecast (standalone, separate from chart forecast)
// ---------------------------------------------------------------------------

export class Forecast {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async getForecast(): Promise<unknown> {
    return this.client.get(`/forecast/${e(this.id)}`);
  }

  async setParameters(params: Record<string, unknown>): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/forecast/${e(this.id)}/parameters`, params);
  }

  async execute(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/forecast/${e(this.id)}/execute`);
  }

  async getResults(): Promise<unknown> {
    return this.client.get(`/forecast/${e(this.id)}/results`);
  }

  async setAlgorithm(algorithm: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/forecast/${e(this.id)}/algorithm`, { algorithm });
  }

  async getAlgorithm(): Promise<string> {
    return this.client.get<string>(`/forecast/${e(this.id)}/algorithm`);
  }
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export interface ExportOptions {
  format?: string;
  includeHeader?: boolean;
  includeTitle?: boolean;
  pageOrientation?: 'portrait' | 'landscape';
  paperSize?: string;
}

export class ExportService {
  constructor(private readonly client: SACRestAPIClient) {}

  async toPdf(widgetId: string, options?: ExportOptions): Promise<Blob> {
    return this.client.post<Blob>(`/export/pdf`, { widgetId, ...options });
  }

  async toPng(widgetId: string, options?: ExportOptions): Promise<Blob> {
    return this.client.post<Blob>(`/export/png`, { widgetId, ...options });
  }

  async toExcel(widgetId: string, options?: ExportOptions): Promise<Blob> {
    return this.client.post<Blob>(`/export/excel`, { widgetId, ...options });
  }

  async toCsv(widgetId: string, options?: ExportOptions): Promise<Blob> {
    return this.client.post<Blob>(`/export/csv`, { widgetId, ...options });
  }

  async toWord(widgetId: string, options?: ExportOptions): Promise<Blob> {
    return this.client.post<Blob>(`/export/word`, { widgetId, ...options });
  }
}

// ---------------------------------------------------------------------------
// MultiAction
// ---------------------------------------------------------------------------

export class MultiAction {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async addAction(actionId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/multiaction/${e(this.id)}/actions`, { actionId });
  }

  async removeAction(actionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/multiaction/${e(this.id)}/actions/${e(actionId)}`);
  }

  async execute(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/multiaction/${e(this.id)}/execute`);
  }

  async getActions(): Promise<string[]> {
    return this.client.get<string[]>(`/multiaction/${e(this.id)}/actions`);
  }

  async clearActions(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/multiaction/${e(this.id)}/actions`);
  }

  async setSequential(sequential: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/multiaction/${e(this.id)}/sequential`, { sequential });
  }

  async isSequential(): Promise<boolean> {
    return this.client.get<boolean>(`/multiaction/${e(this.id)}/sequential`);
  }
}

// ---------------------------------------------------------------------------
// LinkedAnalysis
// ---------------------------------------------------------------------------

export class LinkedAnalysis {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async link(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/linkedanalysis/${e(this.id)}/link`, { widgetId });
  }

  async unlink(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/linkedanalysis/${e(this.id)}/unlink`, { widgetId });
  }

  async getLinkedWidgets(): Promise<string[]> {
    return this.client.get<string[]>(`/linkedanalysis/${e(this.id)}/widgets`);
  }

  async setFilterPropagation(enabled: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/linkedanalysis/${e(this.id)}/filterPropagation`, { enabled });
  }

  async isLinked(): Promise<boolean> {
    return this.client.get<boolean>(`/linkedanalysis/${e(this.id)}/linked`);
  }

  async getSourceWidget(): Promise<string> {
    return this.client.get<string>(`/linkedanalysis/${e(this.id)}/source`);
  }
}

// ---------------------------------------------------------------------------
// DataBindings
// ---------------------------------------------------------------------------

export interface DataBindingConfig {
  dataSource: string;
  dimensions?: string[];
  measures?: string[];
}

export class DataBindings {
  constructor(private readonly client: SACRestAPIClient, public readonly widgetId: string) {}

  async getBinding(name: string): Promise<DataBindingConfig> {
    return this.client.get<DataBindingConfig>(`/databindings/${e(this.widgetId)}/${e(name)}`);
  }

  async setBinding(name: string, config: DataBindingConfig): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/databindings/${e(this.widgetId)}/${e(name)}`, config);
  }

  async removeBinding(name: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/databindings/${e(this.widgetId)}/${e(name)}`);
  }

  async getBindings(): Promise<Record<string, DataBindingConfig>> {
    return this.client.get(`/databindings/${e(this.widgetId)}`);
  }

  async clearBindings(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/databindings/${e(this.widgetId)}`);
  }
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

export interface SimulationScenario {
  id: string;
  name: string;
  parameters: Record<string, unknown>;
}

export class Simulation {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async run(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/simulation/${e(this.id)}/run`);
  }

  async reset(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/simulation/${e(this.id)}/reset`);
  }

  async getScenarios(): Promise<SimulationScenario[]> {
    return this.client.get<SimulationScenario[]>(`/simulation/${e(this.id)}/scenarios`);
  }

  async addScenario(scenario: Omit<SimulationScenario, 'id'>): Promise<SimulationScenario> {
    return this.client.post<SimulationScenario>(`/simulation/${e(this.id)}/scenarios`, scenario);
  }

  async removeScenario(scenarioId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/simulation/${e(this.id)}/scenarios/${e(scenarioId)}`);
  }

  async compareScenarios(scenarioIds: string[]): Promise<unknown> {
    return this.client.post(`/simulation/${e(this.id)}/compare`, { scenarioIds });
  }
}

// ---------------------------------------------------------------------------
// Alert
// ---------------------------------------------------------------------------

export interface AlertCondition {
  measure: string;
  operator: string;
  threshold: number;
}

export class Alert {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async create(condition: AlertCondition): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/alert/create`, { ...condition, alertId: this.id });
  }

  async deleteAlert(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/alert/${e(this.id)}`);
  }

  async getAlerts(): Promise<Array<{ id: string; condition: AlertCondition; triggered: boolean }>> {
    return this.client.get(`/alert`);
  }

  async trigger(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/alert/${e(this.id)}/trigger`);
  }

  async setCondition(condition: AlertCondition): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/alert/${e(this.id)}/condition`, condition);
  }

  async getCondition(): Promise<AlertCondition> {
    return this.client.get<AlertCondition>(`/alert/${e(this.id)}/condition`);
  }
}

// ---------------------------------------------------------------------------
// BookmarkSet + BookmarkInfo
// ---------------------------------------------------------------------------

export interface BookmarkInfo {
  id: string;
  name: string;
  description?: string;
  createdDate?: string;
  modifiedDate?: string;
  createdBy?: string;
  global?: boolean;
  isDefault?: boolean;
}

export interface BookmarkSaveInfo {
  name: string;
  description?: string;
  global?: boolean;
  includeFilters?: boolean;
  includePageState?: boolean;
}

export class BookmarkSet {
  constructor(private readonly client: SACRestAPIClient) {}

  async getBookmarks(): Promise<BookmarkInfo[]> {
    return this.client.get<BookmarkInfo[]>('/bookmarks');
  }

  async createBookmark(info: BookmarkSaveInfo): Promise<BookmarkInfo> {
    return this.client.post<BookmarkInfo>('/bookmarks', info);
  }

  async deleteBookmark(bookmarkId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/bookmarks/${e(bookmarkId)}`);
  }

  async applyBookmark(bookmarkId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/bookmarks/${e(bookmarkId)}/apply`);
  }

  async updateBookmark(bookmarkId: string, info: Partial<BookmarkSaveInfo>): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/bookmarks/${e(bookmarkId)}`, info);
  }

  async getBookmarkById(bookmarkId: string): Promise<BookmarkInfo> {
    return this.client.get<BookmarkInfo>(`/bookmarks/${e(bookmarkId)}`);
  }

  async setDefaultBookmark(bookmarkId: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/bookmarks/${e(bookmarkId)}/default`, {});
  }
}

// ---------------------------------------------------------------------------
// PageState / FilterState
// ---------------------------------------------------------------------------

export class PageState {
  constructor(private readonly client: SACRestAPIClient) {}

  async save(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/pagestate/save');
  }

  async restore(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/pagestate/restore');
  }

  async getFilters(): Promise<unknown> {
    return this.client.get('/pagestate/filters');
  }

  async getVariables(): Promise<unknown> {
    return this.client.get('/pagestate/variables');
  }

  async getSelections(): Promise<unknown> {
    return this.client.get('/pagestate/selections');
  }
}

export class FilterState {
  constructor(private readonly client: SACRestAPIClient) {}

  async getFilters(): Promise<unknown> {
    return this.client.get('/filterstate/filters');
  }

  async setFilters(filters: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>('/filterstate/filters', filters);
  }

  async clear(): Promise<OperationResult> {
    return this.client.del<OperationResult>('/filterstate/filters');
  }

  async save(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/filterstate/save');
  }

  async restore(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/filterstate/restore');
  }
}

// ---------------------------------------------------------------------------
// Commenting / Discussion (Collaboration)
// ---------------------------------------------------------------------------

export interface CommentInfo {
  id: string;
  text: string;
  author?: string;
  createdAt?: string;
  parentId?: string;
  resolved?: boolean;
}

export class Commenting {
  constructor(private readonly client: SACRestAPIClient, public readonly widgetId: string) {}

  async getComments(): Promise<CommentInfo[]> {
    return this.client.get<CommentInfo[]>(`/commenting/${e(this.widgetId)}/comments`);
  }

  async addComment(text: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/commenting/${e(this.widgetId)}/comments`, { text });
  }

  async deleteComment(commentId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/commenting/${e(this.widgetId)}/comments/${e(commentId)}`);
  }

  async replyToComment(commentId: string, text: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/commenting/${e(this.widgetId)}/comments/${e(commentId)}/reply`, { text });
  }

  async editComment(commentId: string, text: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/commenting/${e(this.widgetId)}/comments/${e(commentId)}`, { text });
  }

  async getCommentCount(): Promise<number> {
    return this.client.get<number>(`/commenting/${e(this.widgetId)}/count`);
  }

  async resolve(commentId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/commenting/${e(this.widgetId)}/comments/${e(commentId)}/resolve`);
  }

  async reopen(commentId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/commenting/${e(this.widgetId)}/comments/${e(commentId)}/reopen`);
  }
}

export interface DiscussionMessage {
  id: string;
  text: string;
  author?: string;
  createdAt?: string;
}

export class Discussion {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async getMessages(): Promise<DiscussionMessage[]> {
    return this.client.get<DiscussionMessage[]>(`/discussion/${e(this.id)}/messages`);
  }

  async addMessage(text: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/discussion/${e(this.id)}/messages`, { text });
  }

  async deleteMessage(messageId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/discussion/${e(this.id)}/messages/${e(messageId)}`);
  }

  async getParticipants(): Promise<string[]> {
    return this.client.get<string[]>(`/discussion/${e(this.id)}/participants`);
  }

  async subscribe(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/discussion/${e(this.id)}/subscribe`);
  }

  async unsubscribe(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/discussion/${e(this.id)}/unsubscribe`);
  }
}

// ---------------------------------------------------------------------------
// Display widgets — Text, Image, Shape, WebPage, Icon, GeoMap, KPI, etc.
// ---------------------------------------------------------------------------

export class TextWidget extends Widget {
  async getText(): Promise<string> { return this.client.get(`/display/${e(this.id)}/text`); }
  async setText(text: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/text`, { text }); }
  async setHtmlText(html: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/html`, { html }); }
  async setStyle(style: Record<string, string>): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/style`, style); }
  async getStyle(): Promise<Record<string, string>> { return this.client.get(`/display/${e(this.id)}/style`); }
  async setTooltip(tooltip: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/tooltip`, { tooltip }); }
}

export class ImageWidget extends Widget {
  async getSrc(): Promise<string> { return this.client.get(`/display/${e(this.id)}/src`); }
  async setSrc(src: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/src`, { src }); }
  async setAlt(alt: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/alt`, { alt }); }
  async setSize(width: number, height: number): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/size`, { width, height }); }
}

export class ShapeWidget extends Widget {
  async setStyle(style: Record<string, string>): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/style`, style); }
  async getStyle(): Promise<Record<string, string>> { return this.client.get(`/display/${e(this.id)}/style`); }
  async setType(type: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/type`, { type }); }
  async getType(): Promise<string> { return this.client.get(`/display/${e(this.id)}/type`); }
}

export class WebPageWidget extends Widget {
  async getUrl(): Promise<string> { return this.client.get(`/display/${e(this.id)}/url`); }
  async setUrl(url: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/url`, { url }); }
  async refresh(): Promise<OperationResult> { return this.client.post(`/display/${e(this.id)}/refresh`); }
  async postMessage(message: unknown): Promise<OperationResult> { return this.client.post(`/display/${e(this.id)}/postMessage`, { message }); }
}

export class IconWidget extends Widget {
  async getIcon(): Promise<string> { return this.client.get(`/display/${e(this.id)}/icon`); }
  async setIcon(icon: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/icon`, { icon }); }
  async setSize(size: number): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/size`, { size }); }
  async setColor(color: string): Promise<OperationResult> { return this.client.put(`/display/${e(this.id)}/color`, { color }); }
}

export class GeoMap extends Widget {
  async getDataSource(): Promise<string> { return this.client.get(`/geomap/${e(this.id)}/datasource`); }
  async setDataSource(dsName: string): Promise<OperationResult> { return this.client.put(`/geomap/${e(this.id)}/datasource`, { name: dsName }); }
  async getSelection(): Promise<unknown> { return this.client.get(`/geomap/${e(this.id)}/selection`); }
  async setSelection(sel: unknown): Promise<OperationResult> { return this.client.put(`/geomap/${e(this.id)}/selection`, sel); }
  async getMapType(): Promise<string> { return this.client.get(`/geomap/${e(this.id)}/mapType`); }
  async setMapType(type: string): Promise<OperationResult> { return this.client.put(`/geomap/${e(this.id)}/mapType`, { type }); }
  async setZoom(level: number): Promise<OperationResult> { return this.client.put(`/geomap/${e(this.id)}/zoom`, { level }); }
  async getZoom(): Promise<number> { return this.client.get(`/geomap/${e(this.id)}/zoom`); }
  async setCenter(lat: number, lng: number): Promise<OperationResult> { return this.client.put(`/geomap/${e(this.id)}/center`, { lat, lng }); }
  async refresh(): Promise<OperationResult> { return this.client.post(`/geomap/${e(this.id)}/refresh`); }
}

export class KPI extends Widget {
  async getDataSource(): Promise<string> { return this.client.get(`/kpi/${e(this.id)}/datasource`); }
  async setDataSource(dsName: string): Promise<OperationResult> { return this.client.put(`/kpi/${e(this.id)}/datasource`, { name: dsName }); }
  async getValue(): Promise<number> { return this.client.get(`/kpi/${e(this.id)}/value`); }
  async setValue(value: number): Promise<OperationResult> { return this.client.put(`/kpi/${e(this.id)}/value`, { value }); }
  async getTitle(): Promise<string> { return this.client.get(`/kpi/${e(this.id)}/title`); }
  async setTitle(title: string): Promise<OperationResult> { return this.client.put(`/kpi/${e(this.id)}/title`, { title }); }
  async getTarget(): Promise<number> { return this.client.get(`/kpi/${e(this.id)}/target`); }
  async setTarget(target: number): Promise<OperationResult> { return this.client.put(`/kpi/${e(this.id)}/target`, { target }); }
  async setTrend(trend: string): Promise<OperationResult> { return this.client.put(`/kpi/${e(this.id)}/trend`, { trend }); }
  async refresh(): Promise<OperationResult> { return this.client.post(`/kpi/${e(this.id)}/refresh`); }
}

export class ValueDriverTree extends Widget {
  async getDataSource(): Promise<string> { return this.client.get(`/vdt/${e(this.id)}/datasource`); }
  async setDataSource(dsName: string): Promise<OperationResult> { return this.client.put(`/vdt/${e(this.id)}/datasource`, { name: dsName }); }
  async expandNode(nodeId: string): Promise<OperationResult> { return this.client.post(`/vdt/${e(this.id)}/expand`, { nodeId }); }
  async collapseNode(nodeId: string): Promise<OperationResult> { return this.client.post(`/vdt/${e(this.id)}/collapse`, { nodeId }); }
  async expandAll(): Promise<OperationResult> { return this.client.post(`/vdt/${e(this.id)}/expandAll`); }
  async collapseAll(): Promise<OperationResult> { return this.client.post(`/vdt/${e(this.id)}/collapseAll`); }
  async refresh(): Promise<OperationResult> { return this.client.post(`/vdt/${e(this.id)}/refresh`); }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface GeoMapEvents {
  select: (selection: unknown) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }
