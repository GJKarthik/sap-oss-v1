/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Built-in objects, Timer, TextPool, SearchToInsight,
 *   OData types, cast function, NucleusConsole, NucleusDate, NucleusJSON, NucleusMath
 *
 * Maps to: specs/sacwidgetclient/built-in-objects/, timer/, textpool/,
 *          search-to-insight/, odata-service/, functions/
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/
 */

import type { SACRestAPIClient } from '../client';
import { SACError } from '../client';
import type { OperationResult } from '../types';
import { Widget } from '../widgets';

// ===========================================================================
// NucleusConsole — Structured logging, performance monitoring, analytics
// Spec: built-in-objects/console_client.odps.yaml
// ===========================================================================

export type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'fatal';

export interface LogEntry {
  timestamp: Date;
  level: LogLevel;
  message: string;
  data?: unknown;
  context?: LogContext;
  tags?: string[];
}

export interface LogContext {
  applicationId?: string;
  storyId?: string;
  userId?: string;
  sessionId?: string;
  widgetId?: string;
  dataSource?: string;
  operation?: string;
  correlationId?: string;
}

export interface PerformanceMark {
  name: string;
  timestamp: number;
  metadata?: Record<string, unknown>;
}

export interface PerformanceMeasure {
  name: string;
  startMark: string;
  endMark: string;
  duration: number;
}

export interface AnalyticsEvent {
  eventName: string;
  category: string;
  action: string;
  label?: string;
  value?: number;
  customProperties?: Record<string, unknown>;
  timestamp: Date;
}

export interface LogFilter {
  minLevel?: LogLevel;
  tags?: string[];
  startTime?: Date;
  endTime?: Date;
  search?: string;
}

export interface RemoteLogConfig {
  endpoint: string;
  batchSize: number;
  flushInterval: number;
  retryAttempts: number;
  includeContext: boolean;
}

export class NucleusConsole {
  private readonly buffer: LogEntry[] = [];
  private context: LogContext = {};
  private defaultTags: string[] = [];
  private readonly timers = new Map<string, number>();
  private readonly counts = new Map<string, number>();
  private readonly marks: PerformanceMark[] = [];
  private readonly measures: PerformanceMeasure[] = [];

  constructor(private readonly client: SACRestAPIClient) {}

  // -- Standard log levels ---------------------------------------------------

  debug(message: string, data?: unknown): void { this.log('debug', message, data); }
  info(message: string, data?: unknown): void { this.log('info', message, data); }
  warn(message: string, data?: unknown): void { this.log('warn', message, data); }
  error(message: string, data?: unknown): void { this.log('error', message, data); }
  fatal(message: string, data?: unknown): void { this.log('fatal', message, data); }

  log(level: LogLevel, message: string, data?: unknown): void {
    const entry: LogEntry = {
      timestamp: new Date(),
      level,
      message,
      data,
      context: { ...this.context },
      tags: [...this.defaultTags],
    };
    this.buffer.push(entry);
  }

  // -- Assertion / counting --------------------------------------------------

  assert(condition: boolean, message: string, data?: unknown): void {
    if (!condition) this.error(`Assertion failed: ${message}`, data);
  }

  count(label: string): void {
    const c = (this.counts.get(label) ?? 0) + 1;
    this.counts.set(label, c);
  }

  countReset(label: string): void { this.counts.delete(label); }

  // -- Timing ----------------------------------------------------------------

  time(label: string): void { this.timers.set(label, performance.now()); }

  timeEnd(label: string): number {
    const start = this.timers.get(label);
    if (start === undefined) return 0;
    this.timers.delete(label);
    return performance.now() - start;
  }

  // -- Performance marks / measures ------------------------------------------

  mark(name: string, metadata?: Record<string, unknown>): PerformanceMark {
    const m: PerformanceMark = { name, timestamp: performance.now(), metadata };
    this.marks.push(m);
    return m;
  }

  measure(name: string, startMark: string, endMark?: string): PerformanceMeasure {
    const s = this.marks.find(m => m.name === startMark);
    const eM = endMark ? this.marks.find(m => m.name === endMark) : undefined;
    const duration = (eM?.timestamp ?? performance.now()) - (s?.timestamp ?? 0);
    const meas: PerformanceMeasure = { name, startMark, endMark: endMark ?? '', duration };
    this.measures.push(meas);
    return meas;
  }

  getMarks(): PerformanceMark[] { return [...this.marks]; }
  getMeasures(): PerformanceMeasure[] { return [...this.measures]; }
  clearMarks(name?: string): void {
    if (name) { const idx = this.marks.findIndex(m => m.name === name); if (idx >= 0) this.marks.splice(idx, 1); }
    else this.marks.length = 0;
  }
  clearMeasures(name?: string): void {
    if (name) { const idx = this.measures.findIndex(m => m.name === name); if (idx >= 0) this.measures.splice(idx, 1); }
    else this.measures.length = 0;
  }

  // -- Context / tags --------------------------------------------------------

  setContext(ctx: Partial<LogContext>): void { Object.assign(this.context, ctx); }
  getContext(): LogContext { return { ...this.context }; }
  addDefaultTag(tag: string): void { if (!this.defaultTags.includes(tag)) this.defaultTags.push(tag); }
  removeDefaultTag(tag: string): void { this.defaultTags = this.defaultTags.filter(t => t !== tag); }

  // -- Analytics events (backend) --------------------------------------------

  async trackEvent(event: AnalyticsEvent): Promise<void> {
    await this.client.post('/logs/analytics/event', event);
  }

  async trackUserAction(action: string, label?: string, value?: number): Promise<void> {
    await this.client.post('/logs/analytics/action', { action, label, value });
  }

  async trackError(err: { message: string; stack?: string }, context?: Record<string, unknown>): Promise<void> {
    await this.client.post('/logs/analytics/error', { error: err, context });
  }

  async trackPerformance(name: string, duration: number, metadata?: Record<string, unknown>): Promise<void> {
    await this.client.post('/logs/analytics/performance', { name, duration, metadata });
  }

  // -- Remote logging (backend) ----------------------------------------------

  async flush(): Promise<void> {
    if (this.buffer.length === 0) return;
    await this.client.post('/logs/flush', { entries: this.buffer.splice(0) });
  }

  getBuffer(): LogEntry[] { return [...this.buffer]; }
  clearBuffer(): void { this.buffer.length = 0; }

  // -- Log retrieval (backend) -----------------------------------------------

  async getLogs(filter?: LogFilter): Promise<LogEntry[]> {
    return this.client.post<LogEntry[]>('/logs/query', filter ?? {});
  }

  async searchLogs(query: string, limit?: number): Promise<LogEntry[]> {
    return this.client.post<LogEntry[]>('/logs/search', { query, limit });
  }

  async exportLogs(format: 'json' | 'csv', filter?: LogFilter): Promise<string> {
    return this.client.post<string>('/logs/export', { format, filter });
  }
}

// ===========================================================================
// NucleusDate — Date arithmetic, timezone, business/fiscal calendar
// Spec: built-in-objects/date_client.odps.yaml
// ===========================================================================

export type DateUnit = 'years' | 'months' | 'weeks' | 'days' | 'hours' | 'minutes' | 'seconds' | 'milliseconds';
export type DateTruncUnit = 'year' | 'quarter' | 'month' | 'week' | 'day' | 'hour';

export interface DateComponents {
  year: number;
  month: number;
  date: number;
  hours: number;
  minutes: number;
  seconds: number;
  milliseconds: number;
  dayOfWeek: number;
  dayOfYear: number;
  weekOfYear: number;
  quarter: number;
}

export interface DateDiff {
  years: number;
  months: number;
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
  milliseconds: number;
  totalDays: number;
  totalHours: number;
  totalMinutes: number;
  totalSeconds: number;
  totalMilliseconds: number;
}

export interface DateFormatOptions {
  locale?: string;
  timeZone?: string;
  dateStyle?: 'full' | 'long' | 'medium' | 'short';
  timeStyle?: 'full' | 'long' | 'medium' | 'short';
  pattern?: string;
}

export interface BusinessCalendarOptions {
  holidays?: string[];
  workingDays?: number[];
  factoryCalendarId?: string;
}

export interface FiscalPeriodInfo {
  fiscalYear: number;
  fiscalPeriod: number;
  fiscalQuarter: number;
  periodStart: string;
  periodEnd: string;
  fiscalYearStart: string;
  fiscalYearEnd: string;
}

export interface FiscalYearVariant {
  variantId: string;
  yearStartMonth: number;
  yearStartDay: number;
  periodsPerYear: number;
}

export interface TimeZoneInfo {
  id: string;
  offset: number;
  offsetString: string;
  abbreviation: string;
  isDST: boolean;
}

export class NucleusDate {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly isoString: string,
  ) {}

  // -- Date arithmetic (backend) ---------------------------------------------

  async add(amount: number, unit: DateUnit): Promise<string> {
    return this.client.post<string>('/dates/add', { date: this.isoString, amount, unit });
  }

  async subtract(amount: number, unit: DateUnit): Promise<string> {
    return this.client.post<string>('/dates/subtract', { date: this.isoString, amount, unit });
  }

  async diff(other: string): Promise<DateDiff> {
    return this.client.post<DateDiff>('/dates/diff', { date: this.isoString, other });
  }

  // -- Components / truncation -----------------------------------------------

  async getComponents(): Promise<DateComponents> {
    return this.client.post<DateComponents>('/dates/components', { date: this.isoString });
  }

  async startOf(unit: DateTruncUnit): Promise<string> {
    return this.client.post<string>('/dates/unit/start', { date: this.isoString, unit });
  }

  async endOf(unit: DateTruncUnit): Promise<string> {
    return this.client.post<string>('/dates/unit/end', { date: this.isoString, unit });
  }

  // -- Formatting (backend) --------------------------------------------------

  async format(options: DateFormatOptions): Promise<string> {
    return this.client.post<string>('/dates/format', { date: this.isoString, options });
  }

  async formatRelative(baseDate?: string): Promise<string> {
    return this.client.post<string>('/dates/format-relative', { date: this.isoString, baseDate });
  }

  // -- Timezone (backend) ----------------------------------------------------

  async toTimeZone(timeZone: string): Promise<string> {
    return this.client.post<string>('/dates/timezone/convert', { date: this.isoString, timeZone });
  }

  async getTimeZoneInfo(): Promise<TimeZoneInfo> {
    return this.client.post<TimeZoneInfo>('/dates/timezone/info', { date: this.isoString });
  }

  // -- Business calendar (backend) -------------------------------------------

  async isBusinessDay(options?: BusinessCalendarOptions): Promise<boolean> {
    return this.client.post<boolean>('/dates/business/is-business-day', { date: this.isoString, options });
  }

  async nextBusinessDay(options?: BusinessCalendarOptions): Promise<string> {
    return this.client.post<string>('/dates/business/next', { date: this.isoString, options });
  }

  async previousBusinessDay(options?: BusinessCalendarOptions): Promise<string> {
    return this.client.post<string>('/dates/business/previous', { date: this.isoString, options });
  }

  async addBusinessDays(days: number, options?: BusinessCalendarOptions): Promise<string> {
    return this.client.post<string>('/dates/business/add-days', { date: this.isoString, days, options });
  }

  async businessDaysBetween(other: string, options?: BusinessCalendarOptions): Promise<number> {
    return this.client.post<number>('/dates/business/days-between', { date: this.isoString, other, options });
  }

  // -- Fiscal calendar (backend) ---------------------------------------------

  async getFiscalPeriod(variant?: FiscalYearVariant): Promise<FiscalPeriodInfo> {
    return this.client.post<FiscalPeriodInfo>('/dates/fiscal/period', { date: this.isoString, variant });
  }

  async toFiscalDate(variant?: FiscalYearVariant): Promise<string> {
    return this.client.post<string>('/dates/fiscal/format', { date: this.isoString, variant });
  }

  // -- Factory ---------------------------------------------------------------

  static from(client: SACRestAPIClient, value: string): NucleusDate {
    return new NucleusDate(client, value);
  }
}

// ===========================================================================
// NucleusJSON — Schema validation, JSONPath, diff/patch, format conversion
// Spec: built-in-objects/json_client.odps.yaml
// ===========================================================================

export interface JSONParseResult<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  errorPosition?: number;
}

export interface JSONSchema {
  $schema?: string;
  type?: string | string[];
  properties?: Record<string, JSONSchema>;
  required?: string[];
  items?: JSONSchema | JSONSchema[];
  additionalProperties?: boolean | JSONSchema;
  minimum?: number;
  maximum?: number;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  enum?: unknown[];
  format?: string;
  $ref?: string;
  definitions?: Record<string, JSONSchema>;
}

export interface ValidationResult {
  valid: boolean;
  errors: ValidationError[];
}

export interface ValidationError {
  path: string;
  message: string;
  keyword: string;
  schemaPath: string;
  data: unknown;
}

export interface JSONPathResult {
  values: unknown[];
  paths: string[];
}

export interface JSONDiff {
  op: 'add' | 'remove' | 'replace' | 'move' | 'copy' | 'test';
  path: string;
  value?: unknown;
  from?: string;
}

export interface JSONPatchResult {
  success: boolean;
  result?: unknown;
  error?: string;
}

export class NucleusJSON {
  constructor(private readonly client: SACRestAPIClient) {}

  // -- Safe parse (local) ----------------------------------------------------

  safeParse<T = unknown>(text: string): JSONParseResult<T> {
    try {
      return { success: true, data: JSON.parse(text) as T };
    } catch (err: unknown) {
      return { success: false, error: String(err) };
    }
  }

  isJSON(text: string): boolean { return this.safeParse(text).success; }

  // -- Schema validation (backend) -------------------------------------------

  async validate(data: unknown, schema: JSONSchema): Promise<ValidationResult> {
    return this.client.post<ValidationResult>('/json/validate', { data, schema });
  }

  async validateBatch(items: unknown[], schema: JSONSchema): Promise<ValidationResult[]> {
    return this.client.post<ValidationResult[]>('/json/validate/batch', { items, schema });
  }

  // -- JSONPath (backend) ----------------------------------------------------

  async query(data: unknown, path: string): Promise<JSONPathResult> {
    return this.client.post<JSONPathResult>('/json/query', { data, path });
  }

  async queryFirst(data: unknown, path: string): Promise<unknown> {
    return this.client.post('/json/query/first', { data, path });
  }

  // -- Diff / patch (backend) ------------------------------------------------

  async diff(source: unknown, target: unknown): Promise<JSONDiff[]> {
    return this.client.post<JSONDiff[]>('/json/diff', { source, target });
  }

  async patch(data: unknown, patches: JSONDiff[]): Promise<JSONPatchResult> {
    return this.client.post<JSONPatchResult>('/json/patch', { data, patches });
  }

  async mergePatch(data: unknown, patchData: unknown): Promise<unknown> {
    return this.client.post('/json/merge-patch', { data, patch: patchData });
  }

  // -- Format conversion (backend) -------------------------------------------

  async toXML(data: unknown, options?: { rootName?: string; arrayElementName?: string }): Promise<string> {
    return this.client.post<string>('/json/convert/xml', { data, options });
  }

  async fromXML(xml: string): Promise<unknown> {
    return this.client.post('/json/convert/from-xml', { xml });
  }

  async toCSV(data: unknown[], options?: { delimiter?: string; headers?: boolean }): Promise<string> {
    return this.client.post<string>('/json/convert/csv', { data, options });
  }

  async fromCSV(csv: string, options?: { delimiter?: string; headers?: boolean }): Promise<unknown[]> {
    return this.client.post<unknown[]>('/json/convert/from-csv', { csv, options });
  }

  async toYAML(data: unknown): Promise<string> {
    return this.client.post<string>('/json/convert/yaml', { data });
  }

  async fromYAML(yaml: string): Promise<unknown> {
    return this.client.post('/json/convert/from-yaml', { yaml });
  }
}

// ===========================================================================
// NucleusMath — Statistics, regression, financial, matrix, interpolation
// Spec: built-in-objects/math_client.odps.yaml
// ===========================================================================

export interface StatisticalSummary {
  count: number;
  sum: number;
  mean: number;
  median: number;
  mode: number[];
  variance: number;
  stdDev: number;
  min: number;
  max: number;
  range: number;
  q1: number;
  q3: number;
  iqr: number;
  skewness: number;
  kurtosis: number;
}

export interface RegressionResult {
  slope: number;
  intercept: number;
  rSquared: number;
  standardError: number;
  predictions: number[];
  residuals: number[];
}

export interface CorrelationResult {
  pearson: number;
  spearman: number;
  kendall: number;
}

export interface FinancialCalcOptions {
  presentValue?: number;
  futureValue?: number;
  rate?: number;
  periods?: number;
  payment?: number;
  paymentAtBeginning?: boolean;
}

export interface MatrixResult {
  data: number[][];
  rows: number;
  cols: number;
}

export interface InterpolationOptions {
  method: 'linear' | 'polynomial' | 'spline' | 'nearest';
  x: number[];
  y: number[];
}

export class NucleusMath {
  constructor(private readonly client: SACRestAPIClient) {}

  // -- Statistical functions (backend) ---------------------------------------

  async summarize(values: number[]): Promise<StatisticalSummary> {
    return this.client.post<StatisticalSummary>('/math/summarize', { values });
  }

  async mean(values: number[]): Promise<number> {
    return this.client.post<number>('/math/mean', { values });
  }

  async median(values: number[]): Promise<number> {
    return this.client.post<number>('/math/median', { values });
  }

  async mode(values: number[]): Promise<number[]> {
    return this.client.post<number[]>('/math/mode', { values });
  }

  async variance(values: number[], population?: boolean): Promise<number> {
    return this.client.post<number>('/math/variance', { values, population });
  }

  async stdDev(values: number[], population?: boolean): Promise<number> {
    return this.client.post<number>('/math/std-dev', { values, population });
  }

  async percentile(values: number[], p: number): Promise<number> {
    return this.client.post<number>('/math/percentile', { values, p });
  }

  async quartiles(values: number[]): Promise<{ q1: number; q2: number; q3: number }> {
    return this.client.post('/math/quartiles', { values });
  }

  // -- Regression & correlation (backend) ------------------------------------

  async linearRegression(x: number[], y: number[]): Promise<RegressionResult> {
    return this.client.post<RegressionResult>('/math/regression/linear', { x, y });
  }

  async polynomialRegression(x: number[], y: number[], degree: number): Promise<RegressionResult> {
    return this.client.post<RegressionResult>('/math/regression/polynomial', { x, y, degree });
  }

  async correlation(x: number[], y: number[]): Promise<CorrelationResult> {
    return this.client.post<CorrelationResult>('/math/correlation', { x, y });
  }

  async covariance(x: number[], y: number[]): Promise<number> {
    return this.client.post<number>('/math/covariance', { x, y });
  }

  // -- Financial functions (backend) -----------------------------------------

  async npv(rate: number, cashFlows: number[]): Promise<number> {
    return this.client.post<number>('/math/financial/npv', { rate, cashFlows });
  }

  async irr(cashFlows: number[], guess?: number): Promise<number> {
    return this.client.post<number>('/math/financial/irr', { cashFlows, guess });
  }

  async pv(options: FinancialCalcOptions): Promise<number> {
    return this.client.post<number>('/math/financial/pv', options);
  }

  async fv(options: FinancialCalcOptions): Promise<number> {
    return this.client.post<number>('/math/financial/fv', options);
  }

  async pmt(options: FinancialCalcOptions): Promise<number> {
    return this.client.post<number>('/math/financial/pmt', options);
  }

  // -- Interpolation (backend) -----------------------------------------------

  async interpolate(xVal: number, options: InterpolationOptions): Promise<number> {
    return this.client.post<number>('/math/interpolate', { xVal, method: options.method, x: options.x, y: options.y });
  }

  async interpolateArray(xValues: number[], options: InterpolationOptions): Promise<number[]> {
    return this.client.post<number[]>('/math/interpolate/batch', { xValues, method: options.method, x: options.x, y: options.y });
  }

  // -- Matrix operations (backend) -------------------------------------------

  async matrixMultiply(a: number[][], b: number[][]): Promise<MatrixResult> {
    return this.client.post<MatrixResult>('/math/matrix/multiply', { a, b });
  }

  async matrixInverse(matrix: number[][]): Promise<MatrixResult> {
    return this.client.post<MatrixResult>('/math/matrix/inverse', { matrix });
  }

  async matrixDeterminant(matrix: number[][]): Promise<number> {
    return this.client.post<number>('/math/matrix/determinant', { matrix });
  }

  async solveLinearSystem(coefficients: number[][], constants: number[]): Promise<number[]> {
    return this.client.post<number[]>('/math/matrix/solve', { coefficients, constants });
  }

  // -- Array ops (backend) ---------------------------------------------------

  async normalize(values: number[]): Promise<number[]> {
    return this.client.post<number[]>('/math/normalize', { values });
  }

  async scale(values: number[], min: number, max: number): Promise<number[]> {
    return this.client.post<number[]>('/math/scale', { values, min, max });
  }

  // -- Local helpers ---------------------------------------------------------

  static sum(values: number[]): number { return values.reduce((a, b) => a + b, 0); }
  static product(values: number[]): number { return values.reduce((a, b) => a * b, 1); }
  static roundTo(x: number, decimals: number): number { const f = 10 ** decimals; return Math.round(x * f) / f; }
  static degToRad(degrees: number): number { return degrees * (Math.PI / 180); }
  static radToDeg(radians: number): number { return radians * (180 / Math.PI); }
}

// ===========================================================================
// Timer — Simple timer with start/stop and onTimeout event
// Spec: timer/timer_client.odps.yaml
// ===========================================================================

export type TimerEventHandler = () => void;

export class Timer {
  private running = false;
  private timerId: ReturnType<typeof setTimeout> | null = null;
  private handler: TimerEventHandler | null = null;

  constructor(_client: SACRestAPIClient, public readonly id: string) {}

  isRunning(): boolean { return this.running; }

  start(delayInSeconds: number): void {
    this.stop();
    this.running = true;
    this.timerId = setTimeout(() => {
      this.running = false;
      this.timerId = null;
      this.handler?.();
    }, delayInSeconds * 1000);
  }

  stop(): void {
    if (this.timerId !== null) {
      clearTimeout(this.timerId);
      this.timerId = null;
    }
    this.running = false;
  }

  onTimeout(handler: TimerEventHandler): this {
    this.handler = handler;
    return this;
  }
}

// ===========================================================================
// TextPool — Centralized text/string resource management (i18n)
// Spec: textpool/textpool_client.odps.yaml
// ===========================================================================

export class TextPool {
  constructor(private readonly client: SACRestAPIClient, public readonly id: string) {}

  async getText(textId: string): Promise<string> {
    return this.client.get<string>(`/textpool/${e(this.id)}/text/${e(textId)}`);
  }

  static async getTextPool(client: SACRestAPIClient, id: string): Promise<TextPool> {
    return new TextPool(client, id);
  }
}

// ===========================================================================
// SearchToInsight — Natural language query widget
// Spec: search-to-insight/searchtoinsight_client.odps.yaml
// ===========================================================================

export enum SearchToInsightDialogMode {
  New = 'New',
  Existing = 'Existing',
}

export interface SearchToInsightResult {
  question: string;
  success: boolean;
  chartApplied: boolean;
  errorMessage?: string;
}

export interface SearchToInsightEvents {
  searchComplete: (payload: { question: string; success: boolean; chartUpdated: boolean }) => void;
  dialogOpen: (payload: { mode: SearchToInsightDialogMode }) => void;
  dialogClose: () => void;
  variableChange: (payload: { modelId: string; variable: string; values: string[] }) => void;
}

export class SearchToInsight extends Widget {
  async applySearchToChart(question: string, chartWidgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/searchtoinsight/${e(this.id)}/apply`, { question, chartWidgetId },
    );
  }

  async openDialog(
    question: string,
    mode: SearchToInsightDialogMode,
    cleanHistory?: boolean,
    autoSearch?: boolean,
  ): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/searchtoinsight/${e(this.id)}/dialog/open`,
      { question, mode, cleanHistory, autoSearch },
    );
  }

  async closeDialog(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/searchtoinsight/${e(this.id)}/dialog/close`);
  }

  async getVariables(modelId: string): Promise<unknown[]> {
    return this.client.get(`/searchtoinsight/${e(this.id)}/variables/${e(modelId)}`);
  }

  async setVariableValue(modelId: string, variable: string, values: string[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/searchtoinsight/${e(this.id)}/variables/${e(modelId)}/${e(variable)}`, { values },
    );
  }

  static async getSearchToInsight(client: SACRestAPIClient, widgetId: string): Promise<SearchToInsight> {
    return new SearchToInsight(client, widgetId);
  }
}

// ===========================================================================
// OData types
// Spec: odata-service/odataerror_client.odps.yaml
//        odata-service/odataqueryoptions_client.odps.yaml
// ===========================================================================

export interface ODataError {
  code: string;
  message: string;
  target?: string;
  details?: ODataError[];
}

export interface ODataQueryOptions {
  filter?: string;
  orderby?: string;
  select?: string;
  skip?: number;
  top?: number;
}

// ===========================================================================
// Cast function
// Spec: functions/cast_client.odps.yaml
// ===========================================================================

export function cast<T>(value: unknown): T {
  return value as T;
}

// ===========================================================================
// Error classes — from spec error_codes sections (Rule 6)
// ===========================================================================

export class ConsoleBufferOverflowError extends SACError {
  constructor() { super('Log buffer exceeded maximum capacity', 0, 'BUFFER_OVERFLOW'); }
}
export class ConsoleRemoteLogFailedError extends SACError {
  constructor(detail?: string) { super(detail ?? 'Remote logging endpoint unreachable', 502, 'REMOTE_LOG_FAILED'); }
}
export class ConsoleInvalidLogLevelError extends SACError {
  constructor(level: string) { super(`Invalid log level: ${level}`, 0, 'INVALID_LOG_LEVEL'); }
}
export class ConsoleExportFailedError extends SACError {
  constructor(detail?: string) { super(detail ?? 'Log export operation failed', 500, 'EXPORT_FAILED'); }
}

export class DateInvalidDateError extends SACError {
  constructor(input: string) { super(`Cannot parse date from "${input}"`, 0, 'INVALID_DATE'); }
}
export class DateInvalidTimeZoneError extends SACError {
  constructor(tz: string) { super(`Unknown timezone "${tz}"`, 0, 'INVALID_TIMEZONE'); }
}
export class DateInvalidFormatError extends SACError {
  constructor(pattern: string) { super(`Bad date format pattern "${pattern}"`, 0, 'INVALID_FORMAT'); }
}
export class DateCalendarNotFoundError extends SACError {
  constructor(calendarId: string) { super(`Calendar not found: "${calendarId}"`, 404, 'CALENDAR_NOT_FOUND'); }
}
export class DateFiscalVariantError extends SACError {
  constructor(variantId: string) { super(`Invalid fiscal variant "${variantId}"`, 0, 'FISCAL_VARIANT_ERROR'); }
}

export class JSONParseError extends SACError {
  constructor(position?: number) { super(`Invalid JSON${position != null ? ` at position ${position}` : ''}`, 0, 'PARSE_ERROR'); }
}
export class JSONValidationFailedError extends SACError {
  constructor(errorCount: number) { super(`Schema validation failed with ${errorCount} error(s)`, 0, 'VALIDATION_FAILED'); }
}
export class JSONSchemaInvalidError extends SACError {
  constructor() { super('The provided JSON schema is malformed', 0, 'SCHEMA_INVALID'); }
}
export class JSONPathInvalidError extends SACError {
  constructor(path: string) { super(`Bad JSONPath expression "${path}"`, 0, 'PATH_INVALID'); }
}
export class JSONPatchFailedError extends SACError {
  constructor(op: string) { super(`Patch operation "${op}" could not be applied`, 0, 'PATCH_FAILED'); }
}
export class JSONConversionError extends SACError {
  constructor(format: string) { super(`Failed to convert to/from ${format}`, 0, 'CONVERSION_ERROR'); }
}
export class JSONStreamingError extends SACError {
  constructor() { super('JSON streaming parse failed', 0, 'STREAMING_ERROR'); }
}
export class JSONDepthExceededError extends SACError {
  constructor(maxDepth: number) { super(`Object nesting exceeded max depth ${maxDepth}`, 0, 'DEPTH_EXCEEDED'); }
}
export class JSONSizeLimitError extends SACError {
  constructor() { super('JSON payload exceeds maximum allowed size', 0, 'SIZE_LIMIT'); }
}

export class MathDivisionByZeroError extends SACError {
  constructor() { super('Division by zero', 0, 'DIVISION_BY_ZERO'); }
}
export class MathMatrixSingularError extends SACError {
  constructor() { super('Matrix is not invertible', 0, 'MATRIX_SINGULAR'); }
}
export class MathMatrixDimensionMismatchError extends SACError {
  constructor() { super('Incompatible matrix dimensions', 0, 'MATRIX_DIMENSION_MISMATCH'); }
}
export class MathConvergenceError extends SACError {
  constructor(method: string) { super(`${method} did not converge`, 0, 'CONVERGENCE_FAILED'); }
}
export class MathInvalidDistributionError extends SACError {
  constructor(dist: string) { super(`Unknown distribution "${dist}"`, 0, 'INVALID_DISTRIBUTION'); }
}
export class MathInsufficientDataError extends SACError {
  constructor(required: number) { super(`Need at least ${required} data points`, 0, 'INSUFFICIENT_DATA'); }
}

// ---------------------------------------------------------------------------
// Helpers — placed at bottom per .clinerules Rule 9
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }
