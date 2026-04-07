/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Shared type definitions
 *
 * All enums and interfaces derived from ODPS spec files in
 * specs/sacwidgetclient/standard/, datasource/, chart/, planning/, calendar/, etc.
 */

// ---------------------------------------------------------------------------
// JSON primitives
// ---------------------------------------------------------------------------

export type JsonValue = string | number | boolean | null | JsonObject | JsonArray;
export type JsonObject = { [key: string]: JsonValue };
export type JsonArray = JsonValue[];

// ---------------------------------------------------------------------------
// Application enums  (application_client, applicationmode_client, applicationmessagetype_client)
// ---------------------------------------------------------------------------

/** applicationmode_client.odps.yaml — display mode of the analytic application */
export enum ApplicationMode {
  Embed = 'Embed',
  Present = 'Present',
  View = 'View',
}

/** applicationmessagetype_client.odps.yaml — severity for Application.showMessage() */
export enum ApplicationMessageType {
  Error = 'Error',
  Info = 'Info',
  Success = 'Success',
  Warning = 'Warning',
}

/** deviceorientation_client.odps.yaml — device orientation angles */
export enum DeviceOrientation {
  Angle0 = 'Angle0',
  Angle180 = 'Angle180',
  Angle90Clockwise = 'Angle90Clockwise',
  Angle90Counterclockwise = 'Angle90Counterclockwise',
}

/** application_client.odps.yaml — device type where app is running */
export enum DeviceType {
  Desktop = 'Desktop',
  Tablet = 'Tablet',
  Phone = 'Phone',
}

/** application_client.odps.yaml — current view mode */
export enum ViewMode {
  View = 'View',
  Edit = 'Edit',
  Present = 'Present',
}

// ---------------------------------------------------------------------------
// Widget type enum
// ---------------------------------------------------------------------------

export enum WidgetType {
  Chart = 'Chart', Table = 'Table', Text = 'Text', Image = 'Image',
  Shape = 'Shape', Button = 'Button', Dropdown = 'Dropdown',
  Checkbox = 'Checkbox', RadioButton = 'RadioButton', InputField = 'InputField',
  DatePicker = 'DatePicker', Slider = 'Slider', FilterLine = 'FilterLine',
  GeoMap = 'GeoMap', RVisualization = 'RVisualization',
  CustomWidget = 'CustomWidget', Container = 'Container',
}

// ---------------------------------------------------------------------------
// Chart enums  (chart_client.odps.yaml)
// ---------------------------------------------------------------------------

export enum ChartType {
  Bar = 'bar', Column = 'column', Line = 'line', Area = 'area',
  Pie = 'pie', Donut = 'donut', Bubble = 'bubble', Scatter = 'scatter',
  Waterfall = 'waterfall', Treemap = 'treemap', Heatmap = 'heatmap',
  Bullet = 'bullet', Combo = 'combo',
  StackedBar = 'stacked_bar', StackedColumn = 'stacked_column',
  Variance = 'variance',
}

/** chart_client.odps.yaml — Feed enum for organising dimensions/measures */
export enum Feed {
  CategoryAxis = 'categoryAxis',
  Color = 'color',
  ValueAxis = 'valueAxis',
  BubbleWidth = 'bubbleWidth',
  BubbleHeight = 'bubbleHeight',
  Trellis = 'trellis',
}

/** chart_client.odps.yaml — legend position */
export enum ChartLegendPosition {
  Top = 'TOP',
  Bottom = 'BOTTOM',
  Left = 'LEFT',
  Right = 'RIGHT',
  None = 'NONE',
}

export enum ForecastType {
  Automatic = 'Automatic', Linear = 'Linear', Exponential = 'Exponential',
  Logarithmic = 'Logarithmic', Polynomial = 'Polynomial', Power = 'Power',
}

// ---------------------------------------------------------------------------
// DataSource enums
// ---------------------------------------------------------------------------

export enum FilterValueType {
  SingleValue = 'SingleValue', MultipleValue = 'MultipleValue',
  RangeValue = 'RangeValue', AllValue = 'AllValue', ExcludeValue = 'ExcludeValue',
}

export enum VariableValueType {
  Single = 'Single', Multiple = 'Multiple', Range = 'Range', Interval = 'Interval',
}

export enum MemberDisplayMode {
  Key = 'Key', Text = 'Text', KeyAndText = 'KeyAndText', TextAndKey = 'TextAndKey',
}

export enum MemberAccessMode { Default = 'Default', ReadOnly = 'ReadOnly', ReadWrite = 'ReadWrite' }

export enum PauseMode { Off = 'Off', On = 'On', Auto = 'Auto' }

export enum SortDirection { Ascending = 'Ascending', Descending = 'Descending', None = 'None' }

export enum RankDirection { Top = 'Top', Bottom = 'Bottom' }

export enum TimeRangeGranularity {
  Year = 'Year', HalfYear = 'HalfYear', Quarter = 'Quarter', Month = 'Month',
  Week = 'Week', Day = 'Day', Hour = 'Hour', Minute = 'Minute', Second = 'Second',
}

// ---------------------------------------------------------------------------
// Calendar enums
// ---------------------------------------------------------------------------

export enum CalendarTaskType {
  GeneralTask = 'GeneralTask', ReviewTask = 'ReviewTask',
  CompositeTask = 'CompositeTask', Process = 'Process', Event = 'Event',
}

export enum CalendarTaskStatus {
  NotStarted = 'NotStarted', InProgress = 'InProgress', Completed = 'Completed',
  Cancelled = 'Cancelled', OnHold = 'OnHold', Overdue = 'Overdue',
}

// ---------------------------------------------------------------------------
// Planning enums  (planningcategory_client, planningcopyoption_client, datalockingstate_client)
// ---------------------------------------------------------------------------

export enum PlanningCategory { Actual = 'Actual', Plan = 'Plan', Forecast = 'Forecast', Budget = 'Budget' }

export enum PlanningCopyOption {
  Overwrite = 'Overwrite', Add = 'Add', Subtract = 'Subtract',
  Multiply = 'Multiply', Divide = 'Divide',
}

export enum DataLockingState { Unlocked = 'Unlocked', Locked = 'Locked', PartiallyLocked = 'PartiallyLocked' }

// ---------------------------------------------------------------------------
// Data Action enums
// ---------------------------------------------------------------------------

export enum DataActionParameterValueType {
  Member = 'Member', Number = 'Number', String = 'String',
  Date = 'Date', DateTime = 'DateTime',
}

export enum DataActionExecutionStatus {
  Success = 'Success', Failed = 'Failed', PartialSuccess = 'PartialSuccess',
  Cancelled = 'Cancelled', Running = 'Running', Pending = 'Pending',
}

// ---------------------------------------------------------------------------
// Utility enums  (direction_client, layoutunit_client)
// ---------------------------------------------------------------------------

/** direction_client.odps.yaml */
export enum Direction { Horizontal = 'Horizontal', Vertical = 'Vertical' }

/** layoutunit_client.odps.yaml — includes Grid value */
export enum LayoutUnit { Auto = 'Auto', Grid = 'Grid', Percent = 'Percent', Pixel = 'Pixel' }

export enum UrlType { Absolute = 'Absolute', Relative = 'Relative', External = 'External' }
export enum UserType { User = 'User', Team = 'Team', Role = 'Role' }

// ---------------------------------------------------------------------------
// Custom Widget enums  (customwidget_client.odps.yaml)
// ---------------------------------------------------------------------------

export enum CustomWidgetPropertyType {
  String = 'STRING', Integer = 'INTEGER', Number = 'NUMBER', Boolean = 'BOOLEAN',
  Color = 'COLOR', Array = 'ARRAY', Object = 'OBJECT',
}

export enum CustomWidgetState { Loading = 'LOADING', Ready = 'READY', Error = 'ERROR' }

// ---------------------------------------------------------------------------
// Shared interfaces
// ---------------------------------------------------------------------------

/** layoutvalue_client.odps.yaml — dimensional value with unit */
export interface LayoutValue {
  value: number;
  numberValue: number;
  unit: LayoutUnit;
}

export interface OperationResult {
  success: boolean;
  message?: string;
  error?: string;
  errorCode?: string;
}

export interface WidgetState {
  widgetId: string;
  visible: boolean;
  enabled: boolean;
  cssClass?: string;
}

export interface WidgetSearchOptions {
  typeFilter?: WidgetType;
  visibleOnly?: boolean;
  parentId?: string;
  maxResults?: number;
}

export interface UserInfo {
  id: string;
  displayName?: string;
  email?: string;
  userType?: UserType;
}

export interface TeamInfo {
  id: string;
  name?: string;
  members?: string[];
}

/** applicationinfo_client.odps.yaml — native SAC properties */
export interface ApplicationInfo {
  id: string;
  name: string;
  description: string;
}

/** applicationinfo_client.odps.yaml — extended metadata from backend */
export interface ExtendedApplicationInfo extends ApplicationInfo {
  owner: string;
  ownerName?: string;
  ownerEmail?: string;
  createdAt: string;
  modifiedAt: string;
  createdBy: string;
  modifiedBy: string;
  version: string;
  tenant: string;
  tenantName?: string;
  folder?: string;
  folderPath?: string;
  tags?: string[];
  category?: string;
}

export interface ApplicationPermissions {
  canView: boolean;
  canEdit: boolean;
  canDelete: boolean;
  canShare: boolean;
  canExecute: boolean;
  canSchedule: boolean;
  canExport: boolean;
  canDuplicate: boolean;
  isOwner: boolean;
  sharedWith?: SharedUser[];
  publicAccess?: 'none' | 'view' | 'edit';
}

export interface SharedUser {
  userId: string;
  userName: string;
  email?: string;
  permission: 'view' | 'edit' | 'admin';
  sharedAt: string;
  sharedBy: string;
}

export interface ApplicationVersion {
  version: string;
  createdAt: string;
  createdBy: string;
  description?: string;
  isPublished: boolean;
  isCurrent: boolean;
}

export interface ApplicationDependency {
  type: 'model' | 'datasource' | 'connection' | 'script' | 'widget' | 'theme';
  id: string;
  name: string;
  version?: string;
  isRequired: boolean;
}

export interface ApplicationUsage {
  totalViews: number;
  uniqueUsers: number;
  lastAccessed: string;
  avgSessionDuration: number;
  accessByDay?: Array<{ date: string; count: number }>;
}

export type ApplicationStatus = 'draft' | 'published' | 'archived' | 'deprecated';
export type ApplicationType = 'analytic_application' | 'story' | 'dashboard' | 'planning' | 'custom';

export interface ApplicationMetadata {
  info: ExtendedApplicationInfo;
  permissions: ApplicationPermissions;
  status: ApplicationStatus;
  type: ApplicationType;
  dependencies: ApplicationDependency[];
  usage?: ApplicationUsage;
  customProperties?: Record<string, unknown>;
}

/** notificationoptions_client.odps.yaml */
export interface NotificationOptions {
  content: string;
  isSendEmail?: boolean;
  isSendMobileNotification?: boolean;
  mode?: ApplicationMode;
}

/** application_client.odps.yaml — theme info */
export interface ThemeInfo {
  name: string;
  id: string;
  isDark: boolean;
}

/** application_client.odps.yaml — dialog button definition */
export interface DialogButton {
  text: string;
  type: string;
  handler?: string;
}

/** event_client.odps.yaml — event object for handlers */
export interface SACEvent {
  source: string;
  type: string;
  timestamp?: number;
}

/** scriptobject_client.odps.yaml */
export interface ScriptParameter {
  name: string;
  type: string;
  defaultValue?: unknown;
  required: boolean;
}

export interface ScriptMethod {
  name: string;
  parameters?: ScriptParameter[];
  returnType?: string;
}

export interface ScriptExecutionContext {
  callerWidget?: string;
  executionId: string;
  timestamp: string;
}

/** customwidget_client.odps.yaml */
export interface CustomWidgetProperty {
  name: string;
  type: CustomWidgetPropertyType;
  value: unknown;
  defaultValue?: unknown;
}

export interface CustomWidgetDataBinding {
  bindingId: string;
  dataSource: string;
  measures?: string[];
  dimensions?: string[];
}

export interface CustomWidgetEvent {
  eventName: string;
  eventData: Record<string, unknown>;
}

export interface CustomWidgetMessage {
  type: string;
  payload: Record<string, unknown>;
}

export interface UrlParameter {
  name: string;
  value: string;
  type?: UrlType;
}
