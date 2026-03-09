/**
 * @sap-oss/sac-webcomponents-ngx/chart
 *
 * Angular Chart Module for SAP Analytics Cloud visualization.
 * Selector derived from mangle: angular_selector("Chart", "sac-chart")
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacChartModule } from './lib/sac-chart.module';

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export { SacChartComponent } from './lib/components/sac-chart.component';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacChartService } from './lib/services/sac-chart.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  ChartAxisScale,
  ChartAxisScaleEffective,
  ChartNumberFormat,
  ChartQuickActionsVisibility,
  ChartRankOptions,
  ChartSortOptions,
  ChartLegendConfig,
  ForecastConfig,
  ForecastResult,
  SmartGroupingConfig,
  FeedConfig,
  DataChangeInsight,
  DataPoint,
  ChartLegendItem,
  ChartDataSourceLike,
  ChartResultSetLike,
  ChartConfig,
} from './lib/types/chart.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  ChartEvents,
  ChartDataPointClickEvent,
  ChartLegendClickEvent,
  ChartZoomEvent,
  ChartSelectionChangeEvent,
} from './lib/types/chart-events.types';
