/**
 * Advanced types — from sap-sac-webcomponents-ts/src/advanced
 */

export interface SmartDiscoveryInsight {
  type: string;
  description: string;
  confidence?: number;
  relatedDimensions?: string[];
  relatedMeasures?: string[];
}

export interface ExportOptions {
  format?: string;
  includeHeader?: boolean;
  includeTitle?: boolean;
  pageOrientation?: 'portrait' | 'landscape';
  paperSize?: string;
}

export interface DataBindingConfig {
  dataSource: string;
  dimensions?: string[];
  measures?: string[];
}

export interface SimulationScenario {
  id: string;
  name: string;
  parameters: Record<string, unknown>;
}

export interface AlertCondition {
  measure: string;
  operator: string;
  threshold: number;
}

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

export interface CommentInfo {
  id: string;
  text: string;
  author?: string;
  createdAt?: string;
  parentId?: string;
  resolved?: boolean;
}

export interface DiscussionMessage {
  id: string;
  text: string;
  author?: string;
  createdAt?: string;
}

export interface GeoMapConfig {
  mapType?: string;
  zoom?: number;
  center?: { lat: number; lng: number };
  dataSource?: string;
}

export interface KpiConfig {
  title?: string;
  value?: number;
  target?: number;
  trend?: string;
  dataSource?: string;
}

export interface AdvancedWidgetConfig {
  visible?: boolean;
  enabled?: boolean;
  cssClass?: string;
  width?: string;
  height?: string;
}
