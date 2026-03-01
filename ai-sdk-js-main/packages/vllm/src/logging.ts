// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Logging utilities for vLLM client.
 *
 * Provides structured logging with configurable levels, formatters,
 * and automatic sensitive data redaction.
 */

/**
 * Log levels in order of severity.
 */
export enum LogLevel {
  TRACE = 0,
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  FATAL = 5,
  SILENT = 6,
}

/**
 * Log level names for display.
 */
const LOG_LEVEL_NAMES: Record<LogLevel, string> = {
  [LogLevel.TRACE]: 'TRACE',
  [LogLevel.DEBUG]: 'DEBUG',
  [LogLevel.INFO]: 'INFO',
  [LogLevel.WARN]: 'WARN',
  [LogLevel.ERROR]: 'ERROR',
  [LogLevel.FATAL]: 'FATAL',
  [LogLevel.SILENT]: 'SILENT',
};

/**
 * Log entry structure.
 */
export interface LogEntry {
  /**
   * Log level.
   */
  level: LogLevel;

  /**
   * Log message.
   */
  message: string;

  /**
   * Timestamp of the log entry.
   */
  timestamp: Date;

  /**
   * Additional context data.
   */
  context?: Record<string, unknown>;

  /**
   * Error if logging an error.
   */
  error?: Error;

  /**
   * Request ID for correlation.
   */
  requestId?: string;

  /**
   * Duration in milliseconds (for timing logs).
   */
  duration?: number;
}

/**
 * Log formatter function type.
 */
export type LogFormatter = (entry: LogEntry) => string;

/**
 * Log transport function type.
 */
export type LogTransport = (entry: LogEntry, formatted: string) => void;

/**
 * Logger configuration.
 */
export interface LoggerConfig {
  /**
   * Minimum log level to output.
   * @default LogLevel.INFO
   */
  level: LogLevel;

  /**
   * Custom formatter for log messages.
   */
  formatter?: LogFormatter;

  /**
   * Custom transport for log output.
   */
  transport?: LogTransport;

  /**
   * Whether to include timestamps.
   * @default true
   */
  timestamps?: boolean;

  /**
   * Whether to redact sensitive data.
   * @default true
   */
  redactSensitive?: boolean;

  /**
   * Additional fields to redact.
   */
  sensitiveFields?: string[];

  /**
   * Whether to include stack traces in error logs.
   * @default true
   */
  includeStackTraces?: boolean;

  /**
   * Context to include in all log entries.
   */
  defaultContext?: Record<string, unknown>;
}

/**
 * Default logger configuration.
 */
export const DEFAULT_LOGGER_CONFIG: LoggerConfig = {
  level: LogLevel.INFO,
  timestamps: true,
  redactSensitive: true,
  includeStackTraces: true,
  sensitiveFields: [],
};

/**
 * Fields that should be redacted by default.
 */
const DEFAULT_SENSITIVE_FIELDS = [
  'password',
  'token',
  'apiKey',
  'api_key',
  'authorization',
  'auth',
  'secret',
  'credential',
  'credentials',
  'bearer',
  'cookie',
  'session',
  'accessToken',
  'access_token',
  'refreshToken',
  'refresh_token',
  'privateKey',
  'private_key',
];

/**
 * Redact value placeholder.
 */
const REDACTED = '[REDACTED]';

/**
 * Default JSON formatter.
 */
export function jsonFormatter(entry: LogEntry): string {
  const obj: Record<string, unknown> = {
    level: LOG_LEVEL_NAMES[entry.level],
    message: entry.message,
    timestamp: entry.timestamp.toISOString(),
  };

  if (entry.requestId) {
    obj.requestId = entry.requestId;
  }

  if (entry.duration !== undefined) {
    obj.duration = entry.duration;
  }

  if (entry.context && Object.keys(entry.context).length > 0) {
    obj.context = entry.context;
  }

  if (entry.error) {
    obj.error = {
      name: entry.error.name,
      message: entry.error.message,
      stack: entry.error.stack,
    };
  }

  return JSON.stringify(obj);
}

/**
 * Pretty formatter for development.
 */
export function prettyFormatter(entry: LogEntry): string {
  const parts: string[] = [];

  // Timestamp
  const time = entry.timestamp.toISOString().replace('T', ' ').substring(0, 23);
  parts.push(`[${time}]`);

  // Level
  const levelPadded = LOG_LEVEL_NAMES[entry.level].padEnd(5);
  parts.push(`[${levelPadded}]`);

  // Request ID
  if (entry.requestId) {
    parts.push(`[${entry.requestId.substring(0, 8)}]`);
  }

  // Message
  parts.push(entry.message);

  // Duration
  if (entry.duration !== undefined) {
    parts.push(`(${entry.duration}ms)`);
  }

  // Context
  if (entry.context && Object.keys(entry.context).length > 0) {
    parts.push(JSON.stringify(entry.context));
  }

  // Error
  if (entry.error) {
    parts.push(`\n  Error: ${entry.error.message}`);
    if (entry.error.stack) {
      parts.push(`\n${entry.error.stack.split('\n').slice(1).join('\n')}`);
    }
  }

  return parts.join(' ');
}

/**
 * Minimal formatter (just message).
 */
export function minimalFormatter(entry: LogEntry): string {
  return `${LOG_LEVEL_NAMES[entry.level]}: ${entry.message}`;
}

/**
 * Console transport (default).
 */
export function consoleTransport(entry: LogEntry, formatted: string): void {
  switch (entry.level) {
    case LogLevel.TRACE:
    case LogLevel.DEBUG:
      console.debug(formatted);
      break;
    case LogLevel.INFO:
      console.info(formatted);
      break;
    case LogLevel.WARN:
      console.warn(formatted);
      break;
    case LogLevel.ERROR:
    case LogLevel.FATAL:
      console.error(formatted);
      break;
    default:
      console.log(formatted);
  }
}

/**
 * No-op transport (for testing).
 */
export function nullTransport(): void {
  // Do nothing
}

/**
 * Creates a transport that collects logs into an array.
 */
export function createArrayTransport(logs: LogEntry[]): LogTransport {
  return (entry: LogEntry) => {
    logs.push(entry);
  };
}

/**
 * Redacts sensitive fields from an object.
 */
export function redactSensitiveData(
  obj: unknown,
  sensitiveFields: string[] = []
): unknown {
  const allSensitive = [...DEFAULT_SENSITIVE_FIELDS, ...sensitiveFields];

  if (obj === null || obj === undefined) {
    return obj;
  }

  if (typeof obj === 'string') {
    // Check if string looks like an API key or token
    if (obj.length > 20 && /^[a-zA-Z0-9+/=_-]+$/.test(obj)) {
      return REDACTED;
    }
    return obj;
  }

  if (Array.isArray(obj)) {
    return obj.map((item) => redactSensitiveData(item, sensitiveFields));
  }

  if (typeof obj === 'object') {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(obj)) {
      const keyLower = key.toLowerCase();
      if (allSensitive.some((f) => keyLower.includes(f.toLowerCase()))) {
        result[key] = REDACTED;
      } else {
        result[key] = redactSensitiveData(value, sensitiveFields);
      }
    }
    return result;
  }

  return obj;
}

/**
 * Generates a unique request ID.
 */
export function generateRequestId(): string {
  return `req_${Date.now().toString(36)}_${Math.random().toString(36).substring(2, 9)}`;
}

/**
 * Logger class with configurable levels and transports.
 */
export class Logger {
  private config: LoggerConfig;
  private formatter: LogFormatter;
  private transport: LogTransport;

  constructor(config: Partial<LoggerConfig> = {}) {
    this.config = { ...DEFAULT_LOGGER_CONFIG, ...config };
    this.formatter = config.formatter ?? prettyFormatter;
    this.transport = config.transport ?? consoleTransport;
  }

  /**
   * Sets the log level.
   */
  setLevel(level: LogLevel): void {
    this.config.level = level;
  }

  /**
   * Gets the current log level.
   */
  getLevel(): LogLevel {
    return this.config.level;
  }

  /**
   * Checks if a log level is enabled.
   */
  isLevelEnabled(level: LogLevel): boolean {
    return level >= this.config.level;
  }

  /**
   * Creates a log entry and outputs it.
   */
  private log(
    level: LogLevel,
    message: string,
    context?: Record<string, unknown>,
    error?: Error
  ): void {
    if (!this.isLevelEnabled(level)) {
      return;
    }

    // Redact sensitive data if enabled
    let safeContext = context;
    if (this.config.redactSensitive && context) {
      safeContext = redactSensitiveData(
        context,
        this.config.sensitiveFields
      ) as Record<string, unknown>;
    }

    // Build entry
    const entry: LogEntry = {
      level,
      message,
      timestamp: new Date(),
      context: { ...this.config.defaultContext, ...safeContext },
    };

    if (error) {
      entry.error = error;
      if (!this.config.includeStackTraces) {
        entry.error = { ...error, stack: undefined } as Error;
      }
    }

    // Format and transport
    const formatted = this.formatter(entry);
    this.transport(entry, formatted);
  }

  /**
   * Log at TRACE level.
   */
  trace(message: string, context?: Record<string, unknown>): void {
    this.log(LogLevel.TRACE, message, context);
  }

  /**
   * Log at DEBUG level.
   */
  debug(message: string, context?: Record<string, unknown>): void {
    this.log(LogLevel.DEBUG, message, context);
  }

  /**
   * Log at INFO level.
   */
  info(message: string, context?: Record<string, unknown>): void {
    this.log(LogLevel.INFO, message, context);
  }

  /**
   * Log at WARN level.
   */
  warn(message: string, context?: Record<string, unknown>): void {
    this.log(LogLevel.WARN, message, context);
  }

  /**
   * Log at ERROR level.
   */
  error(message: string, error?: Error, context?: Record<string, unknown>): void {
    this.log(LogLevel.ERROR, message, context, error);
  }

  /**
   * Log at FATAL level.
   */
  fatal(message: string, error?: Error, context?: Record<string, unknown>): void {
    this.log(LogLevel.FATAL, message, context, error);
  }

  /**
   * Creates a child logger with additional default context.
   */
  child(context: Record<string, unknown>): Logger {
    return new Logger({
      ...this.config,
      defaultContext: { ...this.config.defaultContext, ...context },
      formatter: this.formatter,
      transport: this.transport,
    });
  }
}

/**
 * Request logger for tracking HTTP requests.
 */
export interface RequestLogData {
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: unknown;
}

/**
 * Response logger for tracking HTTP responses.
 */
export interface ResponseLogData {
  status: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: unknown;
  duration?: number;
}

/**
 * Request logger that tracks request/response pairs.
 */
export class RequestLogger {
  private logger: Logger;
  private sensitiveHeaders = ['authorization', 'x-api-key', 'cookie', 'x-auth-token'];

  constructor(logger?: Logger) {
    this.logger = logger ?? new Logger({ level: LogLevel.DEBUG });
  }

  /**
   * Logs an outgoing request.
   */
  logRequest(requestId: string, data: RequestLogData): void {
    const safeHeaders = this.redactHeaders(data.headers);

    this.logger.debug(`→ ${data.method} ${data.url}`, {
      requestId,
      method: data.method,
      url: data.url,
      headers: safeHeaders,
      bodySize: data.body ? JSON.stringify(data.body).length : 0,
    });

    if (this.logger.isLevelEnabled(LogLevel.TRACE) && data.body) {
      this.logger.trace('Request body', {
        requestId,
        body: redactSensitiveData(data.body),
      });
    }
  }

  /**
   * Logs an incoming response.
   */
  logResponse(requestId: string, data: ResponseLogData): void {
    const safeHeaders = this.redactHeaders(data.headers);
    const durationStr = data.duration ? ` (${data.duration}ms)` : '';

    this.logger.debug(`← ${data.status} ${data.statusText ?? ''}${durationStr}`, {
      requestId,
      status: data.status,
      statusText: data.statusText,
      headers: safeHeaders,
      duration: data.duration,
      bodySize: data.body ? JSON.stringify(data.body).length : 0,
    });

    if (this.logger.isLevelEnabled(LogLevel.TRACE) && data.body) {
      this.logger.trace('Response body', {
        requestId,
        body: redactSensitiveData(data.body),
      });
    }
  }

  /**
   * Logs a request error.
   */
  logError(requestId: string, error: Error, duration?: number): void {
    this.logger.error(`✗ Request failed${duration ? ` (${duration}ms)` : ''}`, error, {
      requestId,
      duration,
    });
  }

  /**
   * Creates a timer for tracking request duration.
   */
  startTimer(): () => number {
    const start = Date.now();
    return () => Date.now() - start;
  }

  /**
   * Redacts sensitive headers.
   */
  private redactHeaders(
    headers?: Record<string, string>
  ): Record<string, string> | undefined {
    if (!headers) return undefined;

    const result: Record<string, string> = {};
    for (const [key, value] of Object.entries(headers)) {
      if (this.sensitiveHeaders.includes(key.toLowerCase())) {
        result[key] = REDACTED;
      } else {
        result[key] = value;
      }
    }
    return result;
  }
}

/**
 * Performance logger for tracking operation timing.
 */
export class PerformanceLogger {
  private logger: Logger;
  private timers: Map<string, number> = new Map();

  constructor(logger?: Logger) {
    this.logger = logger ?? new Logger({ level: LogLevel.DEBUG });
  }

  /**
   * Starts a timer for an operation.
   */
  start(operationId: string, message?: string): void {
    this.timers.set(operationId, Date.now());
    if (message) {
      this.logger.debug(`⏱ Start: ${message}`, { operationId });
    }
  }

  /**
   * Ends a timer and logs the duration.
   */
  end(operationId: string, message?: string): number | undefined {
    const startTime = this.timers.get(operationId);
    if (startTime === undefined) {
      this.logger.warn(`Timer not found: ${operationId}`);
      return undefined;
    }

    const duration = Date.now() - startTime;
    this.timers.delete(operationId);

    this.logger.debug(`⏱ End: ${message ?? operationId}`, {
      operationId,
      duration,
    });

    return duration;
  }

  /**
   * Measures an async operation.
   */
  async measure<T>(
    operationId: string,
    operation: () => Promise<T>,
    message?: string
  ): Promise<T> {
    this.start(operationId, message);
    try {
      const result = await operation();
      this.end(operationId, message);
      return result;
    } catch (error) {
      const duration = Date.now() - (this.timers.get(operationId) ?? Date.now());
      this.timers.delete(operationId);
      this.logger.error(`⏱ Failed: ${message ?? operationId}`, error as Error, {
        operationId,
        duration,
      });
      throw error;
    }
  }
}

/**
 * Creates a default logger instance.
 */
export function createLogger(config?: Partial<LoggerConfig>): Logger {
  return new Logger(config);
}

/**
 * Global logger instance.
 */
let globalLogger: Logger | null = null;

/**
 * Gets or creates the global logger.
 */
export function getGlobalLogger(): Logger {
  if (!globalLogger) {
    globalLogger = new Logger();
  }
  return globalLogger;
}

/**
 * Sets the global logger.
 */
export function setGlobalLogger(logger: Logger): void {
  globalLogger = logger;
}

/**
 * Parse log level from string.
 */
export function parseLogLevel(level: string): LogLevel {
  const upperLevel = level.toUpperCase();
  for (const [key, name] of Object.entries(LOG_LEVEL_NAMES)) {
    if (name === upperLevel) {
      return parseInt(key, 10) as LogLevel;
    }
  }
  return LogLevel.INFO;
}