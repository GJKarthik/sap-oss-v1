/**
 * Advanced event types — from sap-sac-webcomponents-ts/src/advanced
 */

export interface GeoMapEvents {
  select: (selection: unknown) => void;
}

export interface SmartDiscoveryCompleteEvent {
  insights: number;
  duration: number;
}

export interface ForecastCompleteEvent {
  algorithm: string;
  dataPoints: number;
}

export interface ExportCompleteEvent {
  format: string;
  size: number;
}

export interface BookmarkApplyEvent {
  bookmarkId: string;
  bookmarkName: string;
}

export interface CommentAddEvent {
  commentId: string;
  text: string;
  author?: string;
}

export interface SimulationRunEvent {
  scenarioId: string;
  duration: number;
}

export interface AlertTriggerEvent {
  alertId: string;
  measure: string;
  value: number;
  threshold: number;
}
