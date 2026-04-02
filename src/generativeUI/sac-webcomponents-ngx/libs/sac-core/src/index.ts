/**
 * @sap-oss/sac-webcomponents-ngx/core
 *
 * Core Angular module for SAP Analytics Cloud integration.
 * Provides base services, types, and utilities.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacCoreModule } from './lib/sac-core.module';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacConfigService } from './lib/services/sac-config.service';
export { SacApiService } from './lib/services/sac-api.service';
export { SacAuthService } from './lib/services/sac-auth.service';
export { SacEventService } from './lib/services/sac-event.service';

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

export { SAC_CONFIG, SAC_API_URL, SAC_AUTH_TOKEN } from './lib/tokens';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  SacConfig,
  SacApiConfig,
  SacAuthConfig,
} from './lib/types/config.types';

export type {
  SacApiResponse,
  SacApiError,
  SacPaginatedResponse,
} from './lib/types/api.types';

export type {
  SacEvent,
  SacEventHandler,
  SacEventType,
} from './lib/types/event.types';

// ---------------------------------------------------------------------------
// Enums (from sap-sac-webcomponents-ts)
// ---------------------------------------------------------------------------

export {
  ApplicationMode,
  ApplicationMessageType,
  DeviceOrientation,
  DeviceType,
  ViewMode,
  WidgetType,
} from './lib/enums/application.enums';

export {
  ChartType,
  Feed,
  ChartLegendPosition,
  ForecastType,
} from './lib/enums/chart.enums';

export {
  FilterValueType,
  VariableValueType,
  MemberDisplayMode,
  MemberAccessMode,
  PauseMode,
  SortDirection,
  RankDirection,
  TimeRangeGranularity,
} from './lib/enums/datasource.enums';

export {
  PlanningCategory,
  PlanningCopyOption,
  DataLockingState,
  DataActionParameterValueType,
  DataActionExecutionStatus,
} from './lib/enums/planning.enums';

export {
  CalendarTaskType,
  CalendarTaskStatus,
} from './lib/enums/calendar.enums';

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

export type {
  ApplicationInfo,
  ExtendedApplicationInfo,
  ApplicationPermissions,
  ApplicationMetadata,
  ThemeInfo,
  UserInfo,
  TeamInfo,
} from './lib/interfaces/application.interfaces';

export type {
  WidgetState,
  WidgetSearchOptions,
  LayoutValue,
  OperationResult,
} from './lib/interfaces/widget.interfaces';

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

export { SacDateUtils } from './lib/utils/date.utils';
export { SacStringUtils } from './lib/utils/string.utils';
export { SacMathUtils } from './lib/utils/math.utils';

// ---------------------------------------------------------------------------
// Decorators
// ---------------------------------------------------------------------------

export { SacInput } from './lib/decorators/sac-input.decorator';
export { SacOutput } from './lib/decorators/sac-output.decorator';
export { SacWidget } from './lib/decorators/sac-widget.decorator';

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

export const SAC_NGX_VERSION = '1.0.0';
export const SAC_API_VERSION = '2025.19';
