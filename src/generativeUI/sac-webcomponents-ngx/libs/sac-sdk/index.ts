/**
 * @sap-oss/sac-webcomponents-ngx/sdk
 *
 * TypeScript SDK for SAP Analytics Cloud widget development
 * powered by the Nucleus platform.
 *
 * Covers 119 SAC widgets, 22 enums, 10 modules.
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/
 * Spec:    hana-bdc-runtime/facts/sac/
 */

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export { SACRestAPIClient, SACError, EventEmitter } from './client';
export type { ClientConfig, ApiResponse, EventHandler } from './client';

// ---------------------------------------------------------------------------
// Shared types & enums
// ---------------------------------------------------------------------------

export {
  ApplicationMode, ApplicationMessageType, DeviceOrientation,
  WidgetType, ChartType, Feed, ForecastType, ChartLegendPosition,
  FilterValueType, VariableValueType, MemberDisplayMode, MemberAccessMode, PauseMode,
  SortDirection, RankDirection, TimeRangeGranularity,
  CalendarTaskType, CalendarTaskStatus,
  PlanningCategory, PlanningCopyOption, DataLockingState,
  DataActionParameterValueType, DataActionExecutionStatus,
  Direction, LayoutUnit, UrlType, UserType,
  DeviceType, ViewMode, CustomWidgetPropertyType, CustomWidgetState,
} from './types';

export type {
  JsonValue, JsonObject, JsonArray,
  LayoutValue, OperationResult, WidgetState, WidgetSearchOptions,
  UserInfo, TeamInfo, ApplicationInfo, ExtendedApplicationInfo,
  ApplicationPermissions, SharedUser, ApplicationVersion,
  ApplicationDependency, ApplicationUsage, ApplicationMetadata,
  ApplicationStatus, ApplicationType,
  NotificationOptions, ThemeInfo, DialogButton, SACEvent,
  ScriptParameter, ScriptMethod, ScriptExecutionContext,
  CustomWidgetProperty, CustomWidgetDataBinding, CustomWidgetEvent, CustomWidgetMessage,
  UrlParameter,
} from './types';

// ---------------------------------------------------------------------------
// Core
// ---------------------------------------------------------------------------

export {
  Application, ScriptObject, NucleusApplicationInfo, Layout,
  StringUtils, DateUtils, MathUtils,
  ApplicationNotFoundError, PermissionDeniedError, UserNotFoundError,
  TagExistsError, PropertyNotFoundError,
} from './core';
export type { NumberFormatConfig, DateFormatConfig, ConditionalFormatRule, ApplicationEvents } from './core';

// ---------------------------------------------------------------------------
// DataSource
// ---------------------------------------------------------------------------

export { DataSource, ResultSet, Selection } from './datasource';
export type { DataSourceEvents } from './datasource';
export {
  DimensionType, MeasureDataType, AggregationType, MeasureType,
  MemberType, MemberStatus, VariableType, VariableInputType, DimensionDataType,
} from './datasource';
export type {
  DimensionInfo, DimensionPropertyInfo, DimensionAttribute, DimensionHierarchy, DimensionProperty,
  MeasureInfo, MeasureFormat, MeasureUnit,
  MemberInfo, MemberAttribute, HierarchyPosition, HierarchyInfo,
  VariableInfo, VariableValue, VariableRange, ModelInfo,
  DataCell, DataPoint, SelectionContext,
  CellInfo, RowInfo, ColumnInfo, ResultSetMetadata,
  SelectionMember, SelectionRange, SelectionOptions, SelectionState,
  FilterValue, TimeRange, SortSpec, RankSpec, MembersOptions,
} from './datasource';

// ---------------------------------------------------------------------------
// Widgets (containers)
// ---------------------------------------------------------------------------

export {
  Widget, Panel, Popup, TabStrip, Tab, PageBook, PageBookPage,
  FlowPanel, Composite, ScrollContainer, Lane, CustomWidget,
} from './widgets';
export type { PopupEvents, TabStripEvents } from './widgets';

// ---------------------------------------------------------------------------
// Chart
// ---------------------------------------------------------------------------

export { Chart } from './chart';
export type {
  ChartAxisScale, ChartAxisScaleEffective, ChartNumberFormat,
  ChartQuickActionsVisibility, ChartRankOptions, ChartSortOptions,
  ChartLegendConfig, ForecastConfig, ForecastResult,
  SmartGroupingConfig, FeedConfig, DataChangeInsight,
  ChartEvents,
} from './chart';

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

export { Table } from './table';
export type {
  TableAxis, TableColumn, TableNumberFormat, TableQuickActionsVisibility,
  TableRankOptions, TableComment, NavigationPanelOptions,
  ChangedCell, TableExportResult,
  TableEvents,
} from './table';

// ---------------------------------------------------------------------------
// Input controls
// ---------------------------------------------------------------------------

export {
  Button, Dropdown, InputField, TextArea, Slider, RangeSlider,
  Switch, CheckboxGroup, RadioButtonGroup, ListBox,
  DatePicker, TimePicker, DateTimePicker, CalendarWidget,
  FilterLine, InputControl, ColorPicker, FileUploader,
} from './input';
export type {
  SelectionItem,
  ButtonEvents, DropdownEvents, InputFieldEvents, TextAreaEvents,
  SliderEvents, RangeSliderEvents, SwitchEvents,
  CheckboxGroupEvents, RadioButtonGroupEvents, ListBoxEvents,
  DatePickerEvents, TimePickerEvents,
} from './input';

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

export {
  PlanningModel, DataAction, BPCPlanningSequence,
  Allocation, PlanningPanel,
  DataLockingScope, PlanningVersionType, PlanningAreaStatus,
  PrivatePublishConflict, PublicPublishConflict,
} from './planning';
export type {
  PlanningSession, LockInfo, VersionInfo,
  PlanningAreaInfo, PlanningAreaFilter, PlanningAreaMemberInfo,
  PrivateVersionPublishOptions, PublicVersionPublishOptions,
  DataActionParameter, DataActionResult,
  AllocationParameter, BPCVariableInfo, BPCExecutionResponse,
} from './planning';

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

export { CalendarService } from './calendar';
export type {
  CalendarTask, CalendarEvent, CalendarProcess,
  CalendarReminder, CalendarFilter,
  CalendarEvents,
} from './calendar';

// ---------------------------------------------------------------------------
// Advanced (includes display, collaboration, state, bookmarks)
// ---------------------------------------------------------------------------

export {
  SmartDiscovery, Forecast, ExportService, MultiAction,
  LinkedAnalysis, DataBindings, Simulation, Alert,
  BookmarkSet, PageState, FilterState,
  Commenting, Discussion,
  TextWidget, ImageWidget, ShapeWidget, WebPageWidget, IconWidget,
  GeoMap, KPI, ValueDriverTree,
} from './advanced';
export type {
  SmartDiscoveryInsight, ExportOptions, DataBindingConfig,
  SimulationScenario, AlertCondition,
  BookmarkInfo, BookmarkSaveInfo,
  CommentInfo, DiscussionMessage,
  GeoMapEvents,
} from './advanced';

// ---------------------------------------------------------------------------
// Built-in objects + small specs
// ---------------------------------------------------------------------------

export {
  NucleusConsole, NucleusDate, NucleusJSON, NucleusMath,
  Timer, TextPool, SearchToInsight,
  SearchToInsightDialogMode,
  cast,
  ConsoleBufferOverflowError, ConsoleRemoteLogFailedError,
  ConsoleInvalidLogLevelError, ConsoleExportFailedError,
  DateInvalidDateError, DateInvalidTimeZoneError, DateInvalidFormatError,
  DateCalendarNotFoundError, DateFiscalVariantError,
  JSONParseError, JSONValidationFailedError, JSONSchemaInvalidError,
  JSONPathInvalidError, JSONPatchFailedError, JSONConversionError,
  JSONStreamingError, JSONDepthExceededError, JSONSizeLimitError,
  MathDivisionByZeroError, MathMatrixSingularError,
  MathMatrixDimensionMismatchError, MathConvergenceError,
  MathInvalidDistributionError, MathInsufficientDataError,
} from './builtins';
export type {
  LogLevel, LogEntry, LogContext, PerformanceMark, PerformanceMeasure,
  AnalyticsEvent, LogFilter, RemoteLogConfig,
  DateUnit, DateTruncUnit, DateComponents, DateDiff, DateFormatOptions,
  BusinessCalendarOptions, FiscalPeriodInfo, FiscalYearVariant, TimeZoneInfo,
  JSONParseResult, JSONSchema, ValidationResult, ValidationError,
  JSONPathResult, JSONDiff, JSONPatchResult,
  StatisticalSummary, RegressionResult, CorrelationResult,
  FinancialCalcOptions, MatrixResult, InterpolationOptions,
  TimerEventHandler, SearchToInsightResult, SearchToInsightEvents,
  ODataError, ODataQueryOptions,
} from './builtins';

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

export const VERSION = '0.1.0';
export const SAC_API_VERSION = '2025.19';

// ---------------------------------------------------------------------------
// Default export
// ---------------------------------------------------------------------------

export { SACRestAPIClient as default } from './client';
