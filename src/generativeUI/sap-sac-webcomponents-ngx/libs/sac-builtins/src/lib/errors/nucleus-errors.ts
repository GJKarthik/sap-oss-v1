/**
 * Nucleus Error Classes
 *
 * Mirrors error classes from sap-sac-webcomponents-ts/src/builtins.
 * Each error has a unique code and descriptive message.
 */

// ---------------------------------------------------------------------------
// Base
// ---------------------------------------------------------------------------

export class NucleusError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly details?: string,
  ) {
    super(message);
    this.name = 'NucleusError';
  }
}

// ---------------------------------------------------------------------------
// Console errors
// ---------------------------------------------------------------------------

export class ConsoleBufferOverflowError extends NucleusError {
  constructor(details?: string) {
    super('CONSOLE_BUFFER_OVERFLOW', 'Console log buffer has exceeded its maximum capacity', details);
    this.name = 'ConsoleBufferOverflowError';
  }
}

export class ConsoleRemoteLogFailedError extends NucleusError {
  constructor(details?: string) {
    super('CONSOLE_REMOTE_LOG_FAILED', 'Failed to send logs to remote endpoint', details);
    this.name = 'ConsoleRemoteLogFailedError';
  }
}

export class ConsoleInvalidLogLevelError extends NucleusError {
  constructor(details?: string) {
    super('CONSOLE_INVALID_LOG_LEVEL', 'Invalid log level specified', details);
    this.name = 'ConsoleInvalidLogLevelError';
  }
}

export class ConsoleExportFailedError extends NucleusError {
  constructor(details?: string) {
    super('CONSOLE_EXPORT_FAILED', 'Failed to export console logs', details);
    this.name = 'ConsoleExportFailedError';
  }
}

// ---------------------------------------------------------------------------
// Date errors
// ---------------------------------------------------------------------------

export class DateInvalidDateError extends NucleusError {
  constructor(details?: string) {
    super('DATE_INVALID', 'Invalid date value provided', details);
    this.name = 'DateInvalidDateError';
  }
}

export class DateInvalidTimeZoneError extends NucleusError {
  constructor(details?: string) {
    super('DATE_INVALID_TIMEZONE', 'Invalid or unknown time zone identifier', details);
    this.name = 'DateInvalidTimeZoneError';
  }
}

export class DateInvalidFormatError extends NucleusError {
  constructor(details?: string) {
    super('DATE_INVALID_FORMAT', 'Invalid date format pattern', details);
    this.name = 'DateInvalidFormatError';
  }
}

export class DateCalendarNotFoundError extends NucleusError {
  constructor(details?: string) {
    super('DATE_CALENDAR_NOT_FOUND', 'Calendar configuration not found', details);
    this.name = 'DateCalendarNotFoundError';
  }
}

export class DateFiscalVariantError extends NucleusError {
  constructor(details?: string) {
    super('DATE_FISCAL_VARIANT', 'Fiscal year variant configuration error', details);
    this.name = 'DateFiscalVariantError';
  }
}

// ---------------------------------------------------------------------------
// JSON errors
// ---------------------------------------------------------------------------

export class JSONParseError extends NucleusError {
  constructor(details?: string) {
    super('JSON_PARSE', 'Failed to parse JSON input', details);
    this.name = 'JSONParseError';
  }
}

export class JSONValidationFailedError extends NucleusError {
  constructor(details?: string) {
    super('JSON_VALIDATION_FAILED', 'JSON schema validation failed', details);
    this.name = 'JSONValidationFailedError';
  }
}

export class JSONSchemaInvalidError extends NucleusError {
  constructor(details?: string) {
    super('JSON_SCHEMA_INVALID', 'JSON schema itself is invalid', details);
    this.name = 'JSONSchemaInvalidError';
  }
}

export class JSONPathInvalidError extends NucleusError {
  constructor(details?: string) {
    super('JSON_PATH_INVALID', 'Invalid JSONPath expression', details);
    this.name = 'JSONPathInvalidError';
  }
}

export class JSONPatchFailedError extends NucleusError {
  constructor(details?: string) {
    super('JSON_PATCH_FAILED', 'JSON patch operation failed', details);
    this.name = 'JSONPatchFailedError';
  }
}

export class JSONConversionError extends NucleusError {
  constructor(details?: string) {
    super('JSON_CONVERSION', 'JSON format conversion failed', details);
    this.name = 'JSONConversionError';
  }
}

export class JSONStreamingError extends NucleusError {
  constructor(details?: string) {
    super('JSON_STREAMING', 'JSON streaming operation failed', details);
    this.name = 'JSONStreamingError';
  }
}

export class JSONDepthExceededError extends NucleusError {
  constructor(details?: string) {
    super('JSON_DEPTH_EXCEEDED', 'JSON nesting depth limit exceeded', details);
    this.name = 'JSONDepthExceededError';
  }
}

export class JSONSizeLimitError extends NucleusError {
  constructor(details?: string) {
    super('JSON_SIZE_LIMIT', 'JSON document exceeds maximum size limit', details);
    this.name = 'JSONSizeLimitError';
  }
}

// ---------------------------------------------------------------------------
// Math errors
// ---------------------------------------------------------------------------

export class MathDivisionByZeroError extends NucleusError {
  constructor(details?: string) {
    super('MATH_DIVISION_BY_ZERO', 'Division by zero', details);
    this.name = 'MathDivisionByZeroError';
  }
}

export class MathMatrixSingularError extends NucleusError {
  constructor(details?: string) {
    super('MATH_MATRIX_SINGULAR', 'Matrix is singular and cannot be inverted', details);
    this.name = 'MathMatrixSingularError';
  }
}

export class MathMatrixDimensionMismatchError extends NucleusError {
  constructor(details?: string) {
    super('MATH_MATRIX_DIM_MISMATCH', 'Matrix dimensions do not match for the requested operation', details);
    this.name = 'MathMatrixDimensionMismatchError';
  }
}

export class MathConvergenceError extends NucleusError {
  constructor(details?: string) {
    super('MATH_CONVERGENCE', 'Iterative calculation did not converge', details);
    this.name = 'MathConvergenceError';
  }
}

export class MathInvalidDistributionError extends NucleusError {
  constructor(details?: string) {
    super('MATH_INVALID_DISTRIBUTION', 'Invalid distribution parameters', details);
    this.name = 'MathInvalidDistributionError';
  }
}

export class MathInsufficientDataError extends NucleusError {
  constructor(details?: string) {
    super('MATH_INSUFFICIENT_DATA', 'Insufficient data points for the requested calculation', details);
    this.name = 'MathInsufficientDataError';
  }
}
