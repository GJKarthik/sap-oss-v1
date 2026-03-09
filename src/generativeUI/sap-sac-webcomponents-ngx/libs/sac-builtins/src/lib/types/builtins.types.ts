/**
 * Builtins types — from sap-sac-webcomponents-ts/src/builtins
 */

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  level: LogLevel;
  message: string;
  timestamp: string;
  context?: Record<string, unknown>;
  category?: string;
}

export interface LogContext {
  [key: string]: unknown;
}

export interface PerformanceMark {
  name: string;
  timestamp: number;
}

export interface PerformanceMeasure {
  name: string;
  startMark: string;
  endMark: string;
  duration: number;
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

export interface FiscalCalendarConfig {
  startMonth: number;
  periodsPerYear: number;
  weekStartDay?: number;
}

export interface DateRange {
  start: string;
  end: string;
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

export interface JsonSchemaValidationResult {
  valid: boolean;
  errors?: string[];
}

export interface JsonDiff {
  path: string;
  op: 'add' | 'remove' | 'replace';
  oldValue?: unknown;
  newValue?: unknown;
}

export interface JsonPatch {
  op: 'add' | 'remove' | 'replace' | 'move' | 'copy' | 'test';
  path: string;
  value?: unknown;
  from?: string;
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

export interface RegressionResult {
  slope: number;
  intercept: number;
  rSquared: number;
  standardError: number;
}

export interface CorrelationResult {
  coefficient: number;
  pValue: number;
}

export interface DescriptiveStats {
  mean: number;
  median: number;
  mode: number[];
  stdDev: number;
  variance: number;
  min: number;
  max: number;
  count: number;
  sum: number;
  skewness: number;
  kurtosis: number;
}

// ---------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------

export type TimerEventHandler = () => void;

// ---------------------------------------------------------------------------
// TextPool
// ---------------------------------------------------------------------------

export interface TextPoolEntry {
  key: string;
  value: string;
  language?: string;
}

// ---------------------------------------------------------------------------
// OData types
// ---------------------------------------------------------------------------

export type ODataEdmType =
  | 'Edm.String'
  | 'Edm.Int32'
  | 'Edm.Int64'
  | 'Edm.Decimal'
  | 'Edm.Double'
  | 'Edm.Boolean'
  | 'Edm.DateTime'
  | 'Edm.DateTimeOffset'
  | 'Edm.Time'
  | 'Edm.Guid'
  | 'Edm.Binary';

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export interface NucleusErrorInfo {
  code: string;
  message: string;
  details?: string;
  stack?: string;
}

// ---------------------------------------------------------------------------
// Logging — extended
// ---------------------------------------------------------------------------

export interface AnalyticsEvent {
  name: string;
  category: string;
  properties?: Record<string, unknown>;
  timestamp?: string;
}

export interface LogFilter {
  level?: LogLevel;
  category?: string;
  startTime?: string;
  endTime?: string;
  search?: string;
}

export interface RemoteLogConfig {
  endpoint: string;
  batchSize?: number;
  flushIntervalMs?: number;
  headers?: Record<string, string>;
  retries?: number;
}

// ---------------------------------------------------------------------------
// Date — extended
// ---------------------------------------------------------------------------

export type DateUnit = 'year' | 'month' | 'week' | 'day' | 'hour' | 'minute' | 'second' | 'millisecond';

export type DateTruncUnit = 'year' | 'month' | 'week' | 'day' | 'hour' | 'minute' | 'second';

export interface DateComponents {
  year: number;
  month: number;
  day: number;
  hour?: number;
  minute?: number;
  second?: number;
  millisecond?: number;
}

export interface DateDiff {
  years: number;
  months: number;
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
  milliseconds: number;
}

export interface DateFormatOptions {
  locale?: string;
  pattern?: string;
  timeZone?: string;
  calendar?: string;
}

export interface BusinessCalendarOptions {
  calendarId: string;
  factoryCalendar?: string;
  holidayCalendar?: string;
}

export interface FiscalPeriodInfo {
  year: number;
  period: number;
  startDate: string;
  endDate: string;
}

export interface FiscalYearVariant {
  id: string;
  description?: string;
  startMonth: number;
  periodsPerYear: number;
}

export interface TimeZoneInfo {
  id: string;
  displayName: string;
  offsetMinutes: number;
  isDST: boolean;
}

// ---------------------------------------------------------------------------
// JSON — extended
// ---------------------------------------------------------------------------

export interface JSONParseResult<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  position?: number;
}

export interface JSONSchema {
  $schema?: string;
  type?: string | string[];
  properties?: Record<string, JSONSchema>;
  items?: JSONSchema | JSONSchema[];
  required?: string[];
  additionalProperties?: boolean | JSONSchema;
  enum?: unknown[];
  const?: unknown;
  oneOf?: JSONSchema[];
  anyOf?: JSONSchema[];
  allOf?: JSONSchema[];
  $ref?: string;
  description?: string;
  default?: unknown;
  minimum?: number;
  maximum?: number;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  format?: string;
}

export interface ValidationResult {
  valid: boolean;
  errors: ValidationError[];
}

export interface ValidationError {
  path: string;
  message: string;
  keyword: string;
  params?: Record<string, unknown>;
}

export interface JSONPathResult {
  path: string;
  value: unknown;
}

export interface JSONDiffEntry {
  op: 'add' | 'remove' | 'replace' | 'move' | 'copy';
  path: string;
  value?: unknown;
  oldValue?: unknown;
  from?: string;
}

export interface JSONPatchResult {
  success: boolean;
  data?: unknown;
  error?: string;
  appliedOps: number;
}

// ---------------------------------------------------------------------------
// Math — extended
// ---------------------------------------------------------------------------

export interface StatisticalSummary extends DescriptiveStats {
  percentile25: number;
  percentile75: number;
  iqr: number;
  coefficientOfVariation: number;
}

export interface FinancialCalcOptions {
  rate: number;
  periods: number;
  presentValue?: number;
  futureValue?: number;
  paymentType?: 'beginning' | 'end';
}

export interface MatrixResult {
  data: number[][];
  rows: number;
  cols: number;
  determinant?: number;
}

export interface InterpolationOptions {
  method: 'linear' | 'cubic' | 'spline' | 'polynomial';
  degree?: number;
  extrapolate?: boolean;
}

// ---------------------------------------------------------------------------
// SearchToInsight
// ---------------------------------------------------------------------------

export type SearchToInsightDialogMode = 'search' | 'insight' | 'both';

export interface SearchToInsightResult {
  query: string;
  widgetId?: string;
  chartType?: string;
  dimensions?: string[];
  measures?: string[];
  filters?: Record<string, unknown>;
}

export interface SearchToInsightEvents {
  onSearch?: (query: string) => void;
  onInsightApply?: (result: SearchToInsightResult) => void;
  onDialogClose?: () => void;
}

// ---------------------------------------------------------------------------
// OData — extended
// ---------------------------------------------------------------------------

export interface ODataError {
  code: string;
  message: string;
  target?: string;
  details?: ODataErrorDetail[];
  innererror?: Record<string, unknown>;
}

export interface ODataErrorDetail {
  code: string;
  message: string;
  target?: string;
}

export interface ODataQueryOptions {
  $filter?: string;
  $select?: string;
  $expand?: string;
  $orderby?: string;
  $top?: number;
  $skip?: number;
  $count?: boolean;
  $search?: string;
}
