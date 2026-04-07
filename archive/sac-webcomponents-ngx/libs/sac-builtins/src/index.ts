/**
 * @sap-oss/sac-webcomponents-ngx/builtins
 *
 * Angular Builtins Module for SAP Analytics Cloud.
 * Covers: NucleusConsole, NucleusDate, NucleusJSON, NucleusMath,
 *         Timer, TextPool, SearchToInsight, OData types, error classes.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacBuiltinsModule } from './lib/sac-builtins.module';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { NucleusConsoleService } from './lib/services/nucleus-console.service';
export { NucleusDateService } from './lib/services/nucleus-date.service';
export { NucleusJsonService } from './lib/services/nucleus-json.service';
export { NucleusMathService } from './lib/services/nucleus-math.service';
export { NucleusTimerService } from './lib/services/nucleus-timer.service';
export { NucleusTextPoolService } from './lib/services/nucleus-textpool.service';
export { SearchToInsightService } from './lib/services/search-to-insight.service';

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

export { cast } from './lib/utils/cast';

// ---------------------------------------------------------------------------
// Error classes
// ---------------------------------------------------------------------------

export {
  NucleusError,
  ConsoleBufferOverflowError,
  ConsoleRemoteLogFailedError,
  ConsoleInvalidLogLevelError,
  ConsoleExportFailedError,
  DateInvalidDateError,
  DateInvalidTimeZoneError,
  DateInvalidFormatError,
  DateCalendarNotFoundError,
  DateFiscalVariantError,
  JSONParseError,
  JSONValidationFailedError,
  JSONSchemaInvalidError,
  JSONPathInvalidError,
  JSONPatchFailedError,
  JSONConversionError,
  JSONStreamingError,
  JSONDepthExceededError,
  JSONSizeLimitError,
  MathDivisionByZeroError,
  MathMatrixSingularError,
  MathMatrixDimensionMismatchError,
  MathConvergenceError,
  MathInvalidDistributionError,
  MathInsufficientDataError,
} from './lib/errors/nucleus-errors';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  // Logging
  LogLevel,
  LogEntry,
  LogContext,
  PerformanceMark,
  PerformanceMeasure,
  AnalyticsEvent,
  LogFilter,
  RemoteLogConfig,
  // Date
  FiscalCalendarConfig,
  DateRange,
  DateUnit,
  DateTruncUnit,
  DateComponents,
  DateDiff,
  DateFormatOptions,
  BusinessCalendarOptions,
  FiscalPeriodInfo,
  FiscalYearVariant,
  TimeZoneInfo,
  // JSON
  JsonSchemaValidationResult,
  JsonDiff,
  JsonPatch,
  JSONParseResult,
  JSONSchema,
  ValidationResult,
  ValidationError,
  JSONPathResult,
  JSONDiffEntry,
  JSONPatchResult,
  // Math
  RegressionResult,
  CorrelationResult,
  DescriptiveStats,
  StatisticalSummary,
  FinancialCalcOptions,
  MatrixResult,
  InterpolationOptions,
  // Timer
  TimerEventHandler,
  // TextPool
  TextPoolEntry,
  // SearchToInsight
  SearchToInsightDialogMode,
  SearchToInsightResult,
  SearchToInsightEvents,
  // OData
  ODataEdmType,
  ODataError,
  ODataErrorDetail,
  ODataQueryOptions,
  // Errors
  NucleusErrorInfo,
} from './lib/types/builtins.types';
