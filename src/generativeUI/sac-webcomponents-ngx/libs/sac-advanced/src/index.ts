/**
 * @sap-oss/sac-webcomponents-ngx/advanced
 *
 * Angular Advanced Module for SAP Analytics Cloud.
 * Covers: SmartDiscovery, Forecast, Export, MultiAction, LinkedAnalysis,
 *         DataBindings, Simulation, Alert, Bookmarks, PageState, FilterState,
 *         Commenting, Discussion, GeoMap, KPI, ValueDriverTree,
 *         TextWidget, ImageWidget, ShapeWidget, WebPageWidget, IconWidget.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacAdvancedModule } from './lib/sac-advanced.module';

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export { SacGeoMapComponent } from './lib/components/sac-geomap.component';
export { SacKpiComponent } from './lib/components/sac-kpi.component';
export { SacDisplayWidgetComponent, DisplayWidgetType } from './lib/components/sac-display-widget.component';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacAdvancedService } from './lib/services/sac-advanced.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  SmartDiscoveryInsight,
  ExportOptions,
  DataBindingConfig,
  SimulationScenario,
  AlertCondition,
  BookmarkInfo,
  BookmarkSaveInfo,
  CommentInfo,
  DiscussionMessage,
  GeoMapConfig,
  KpiConfig,
  AdvancedWidgetConfig,
} from './lib/types/advanced.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  GeoMapEvents,
  SmartDiscoveryCompleteEvent,
  ForecastCompleteEvent,
  ExportCompleteEvent,
  BookmarkApplyEvent,
  CommentAddEvent,
  SimulationRunEvent,
  AlertTriggerEvent,
} from './lib/types/advanced-events.types';
