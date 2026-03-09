/**
 * Chart Event Types
 *
 * Event interfaces for SAC Chart component outputs.
 * Derived from mangle/sac_widget.mg chart_output facts.
 */

import type { DataPoint } from './chart.types';

/** Chart events interface */
export interface ChartEvents {
  onDataPointClick: ChartDataPointClickEvent;
  onLegendClick: ChartLegendClickEvent;
  onZoom: ChartZoomEvent;
  onSelectionChange: ChartSelectionChangeEvent;
}

/** Data point click event */
export interface ChartDataPointClickEvent {
  dataPoint: DataPoint;
  originalEvent: MouseEvent;
  chartType: string;
  seriesIndex?: number;
  dataIndex?: number;
}

/** Legend click event */
export interface ChartLegendClickEvent {
  legendItem: string;
  legendIndex: number;
  isVisible: boolean;
  originalEvent: MouseEvent;
}

/** Zoom event */
export interface ChartZoomEvent {
  zoomLevel: number;
  zoomDirection: 'in' | 'out' | 'reset';
  viewportRange?: {
    xMin: number;
    xMax: number;
    yMin: number;
    yMax: number;
  };
}

/** Selection change event */
export interface ChartSelectionChangeEvent {
  selectedPoints: DataPoint[];
  deselectedPoints: DataPoint[];
  selectionMode: 'single' | 'multiple';
  source: 'click' | 'drag' | 'api';
}

/** Drill event (for drill-down/drill-up) */
export interface ChartDrillEvent {
  direction: 'down' | 'up';
  dimension: string;
  fromMember: string;
  toMember: string;
  level: number;
}

/** Chart render complete event */
export interface ChartRenderCompleteEvent {
  chartType: string;
  renderTime: number;
  dataPointCount: number;
}