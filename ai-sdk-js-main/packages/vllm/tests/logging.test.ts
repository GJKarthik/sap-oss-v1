/**
 * Logging module tests.
 */

import {
  Logger,
  LogLevel,
  RequestLogger,
  PerformanceLogger,
  createLogger,
  getGlobalLogger,
  setGlobalLogger,
  parseLogLevel,
  jsonFormatter,
  prettyFormatter,
  minimalFormatter,
  nullTransport,
  createArrayTransport,
  redactSensitiveData,
  generateRequestId,
  DEFAULT_LOGGER_CONFIG,
  type LogEntry,
  type LoggerConfig,
} from '../src/logging.js';

describe('Logger', () => {
  describe('constructor', () => {
    it('should create with default config', () => {
      const logger = new Logger();
      expect(logger.getLevel()).toBe(LogLevel.INFO);
    });

    it('should accept custom config', () => {
      const logger = new Logger({ level: LogLevel.DEBUG });
      expect(logger.getLevel()).toBe(LogLevel.DEBUG);
    });
  });

  describe('log levels', () => {
    it('should set and get level', () => {
      const logger = new Logger();
      logger.setLevel(LogLevel.WARN);
      expect(logger.getLevel()).toBe(LogLevel.WARN);
    });

    it('should check if level is enabled', () => {
      const logger = new Logger({ level: LogLevel.INFO });

      expect(logger.isLevelEnabled(LogLevel.TRACE)).toBe(false);
      expect(logger.isLevelEnabled(LogLevel.DEBUG)).toBe(false);
      expect(logger.isLevelEnabled(LogLevel.INFO)).toBe(true);
      expect(logger.isLevelEnabled(LogLevel.WARN)).toBe(true);
      expect(logger.isLevelEnabled(LogLevel.ERROR)).toBe(true);
    });
  });

  describe('logging methods', () => {
    let logs: LogEntry[];
    let logger: Logger;

    beforeEach(() => {
      logs = [];
      logger = new Logger({
        level: LogLevel.TRACE,
        transport: createArrayTransport(logs),
      });
    });

    it('should log trace messages', () => {
      logger.trace('trace message', { key: 'value' });

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.TRACE);
      expect(logs[0].message).toBe('trace message');
      expect(logs[0].context?.key).toBe('value');
    });

    it('should log debug messages', () => {
      logger.debug('debug message');

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.DEBUG);
    });

    it('should log info messages', () => {
      logger.info('info message');

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.INFO);
    });

    it('should log warn messages', () => {
      logger.warn('warn message');

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.WARN);
    });

    it('should log error messages with error object', () => {
      const error = new Error('test error');
      logger.error('error message', error, { extra: 'data' });

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.ERROR);
      expect(logs[0].error).toBe(error);
      expect(logs[0].context?.extra).toBe('data');
    });

    it('should log fatal messages', () => {
      const error = new Error('fatal error');
      logger.fatal('fatal message', error);

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.FATAL);
    });
  });

  describe('filtering by level', () => {
    it('should filter logs below threshold', () => {
      const logs: LogEntry[] = [];
      const logger = new Logger({
        level: LogLevel.WARN,
        transport: createArrayTransport(logs),
      });

      logger.trace('trace');
      logger.debug('debug');
      logger.info('info');
      logger.warn('warn');
      logger.error('error');

      expect(logs).toHaveLength(2);
      expect(logs[0].level).toBe(LogLevel.WARN);
      expect(logs[1].level).toBe(LogLevel.ERROR);
    });

    it('should log nothing at SILENT level', () => {
      const logs: LogEntry[] = [];
      const logger = new Logger({
        level: LogLevel.SILENT,
        transport: createArrayTransport(logs),
      });

      logger.fatal('fatal');

      expect(logs).toHaveLength(0);
    });
  });

  describe('sensitive data redaction', () => {
    it('should redact sensitive fields in context', () => {
      const logs: LogEntry[] = [];
      const logger = new Logger({
        level: LogLevel.INFO,
        transport: createArrayTransport(logs),
        redactSensitive: true,
      });

      logger.info('test', { apiKey: 'secret123', safe: 'value' });

      expect(logs[0].context?.apiKey).toBe('[REDACTED]');
      expect(logs[0].context?.safe).toBe('value');
    });

    it('should not redact when disabled', () => {
      const logs: LogEntry[] = [];
      const logger = new Logger({
        level: LogLevel.INFO,
        transport: createArrayTransport(logs),
        redactSensitive: false,
      });

      logger.info('test', { apiKey: 'secret123' });

      expect(logs[0].context?.apiKey).toBe('secret123');
    });
  });

  describe('child logger', () => {
    it('should create child with additional context', () => {
      const logs: LogEntry[] = [];
      const parent = new Logger({
        level: LogLevel.INFO,
        transport: createArrayTransport(logs),
        defaultContext: { service: 'vllm' },
      });

      const child = parent.child({ requestId: 'req-123' });
      child.info('child message');

      expect(logs[0].context?.service).toBe('vllm');
      expect(logs[0].context?.requestId).toBe('req-123');
    });
  });
});

describe('redactSensitiveData', () => {
  it('should return null and undefined unchanged', () => {
    expect(redactSensitiveData(null)).toBeNull();
    expect(redactSensitiveData(undefined)).toBeUndefined();
  });

  it('should redact long string tokens', () => {
    const token = 'sk_abcdefghijklmnopqrstuvwxyz';
    expect(redactSensitiveData(token)).toBe('[REDACTED]');
  });

  it('should not redact short strings', () => {
    expect(redactSensitiveData('hello')).toBe('hello');
  });

  it('should redact object fields by name', () => {
    const obj = {
      password: 'secret',
      username: 'user',
      api_key: 'key123',
    };

    const result = redactSensitiveData(obj) as Record<string, unknown>;

    expect(result.password).toBe('[REDACTED]');
    expect(result.username).toBe('user');
    expect(result.api_key).toBe('[REDACTED]');
  });

  it('should redact nested objects', () => {
    const obj = {
      outer: {
        authorization: 'bearer token',
        data: 'value',
      },
    };

    const result = redactSensitiveData(obj) as Record<string, Record<string, unknown>>;

    expect(result.outer.authorization).toBe('[REDACTED]');
    expect(result.outer.data).toBe('value');
  });

  it('should redact arrays', () => {
    const arr = [{ token: 'secret' }, { token: 'other' }];
    const result = redactSensitiveData(arr) as Array<Record<string, unknown>>;

    expect(result[0].token).toBe('[REDACTED]');
    expect(result[1].token).toBe('[REDACTED]');
  });

  it('should support custom sensitive fields', () => {
    const obj = { customSecret: 'value', other: 'data' };
    const result = redactSensitiveData(obj, ['customSecret']) as Record<string, unknown>;

    expect(result.customSecret).toBe('[REDACTED]');
    expect(result.other).toBe('data');
  });
});

describe('generateRequestId', () => {
  it('should generate unique IDs', () => {
    const id1 = generateRequestId();
    const id2 = generateRequestId();

    expect(id1).not.toBe(id2);
  });

  it('should start with req_ prefix', () => {
    const id = generateRequestId();
    expect(id.startsWith('req_')).toBe(true);
  });
});

describe('formatters', () => {
  const entry: LogEntry = {
    level: LogLevel.INFO,
    message: 'Test message',
    timestamp: new Date('2024-01-15T10:30:00.000Z'),
    context: { key: 'value' },
    requestId: 'req-12345678',
    duration: 150,
  };

  describe('jsonFormatter', () => {
    it('should format as JSON', () => {
      const formatted = jsonFormatter(entry);
      const parsed = JSON.parse(formatted);

      expect(parsed.level).toBe('INFO');
      expect(parsed.message).toBe('Test message');
      expect(parsed.timestamp).toBe('2024-01-15T10:30:00.000Z');
      expect(parsed.context.key).toBe('value');
      expect(parsed.requestId).toBe('req-12345678');
      expect(parsed.duration).toBe(150);
    });

    it('should include error info', () => {
      const errorEntry: LogEntry = {
        ...entry,
        error: new Error('test error'),
      };

      const formatted = jsonFormatter(errorEntry);
      const parsed = JSON.parse(formatted);

      expect(parsed.error.name).toBe('Error');
      expect(parsed.error.message).toBe('test error');
    });
  });

  describe('prettyFormatter', () => {
    it('should format with readable layout', () => {
      const formatted = prettyFormatter(entry);

      expect(formatted).toContain('2024-01-15');
      expect(formatted).toContain('[INFO ]');
      expect(formatted).toContain('Test message');
      expect(formatted).toContain('(150ms)');
    });
  });

  describe('minimalFormatter', () => {
    it('should format minimally', () => {
      const formatted = minimalFormatter(entry);
      expect(formatted).toBe('INFO: Test message');
    });
  });
});

describe('createArrayTransport', () => {
  it('should collect logs into array', () => {
    const logs: LogEntry[] = [];
    const transport = createArrayTransport(logs);

    const entry: LogEntry = {
      level: LogLevel.INFO,
      message: 'test',
      timestamp: new Date(),
    };

    transport(entry, 'formatted');

    expect(logs).toHaveLength(1);
    expect(logs[0]).toBe(entry);
  });
});

describe('nullTransport', () => {
  it('should not throw', () => {
    expect(() => nullTransport()).not.toThrow();
  });
});

describe('RequestLogger', () => {
  let logs: LogEntry[];
  let requestLogger: RequestLogger;

  beforeEach(() => {
    logs = [];
    const logger = new Logger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });
    requestLogger = new RequestLogger(logger);
  });

  describe('logRequest', () => {
    it('should log outgoing request', () => {
      requestLogger.logRequest('req-1', {
        method: 'POST',
        url: 'http://localhost:8000/v1/chat/completions',
        headers: { 'Content-Type': 'application/json' },
        body: { model: 'llama' },
      });

      expect(logs).toHaveLength(1);
      expect(logs[0].message).toContain('POST');
      expect(logs[0].message).toContain('/v1/chat/completions');
    });

    it('should redact sensitive headers', () => {
      requestLogger.logRequest('req-1', {
        method: 'GET',
        url: 'http://test.com',
        headers: { Authorization: 'Bearer secret' },
      });

      expect(logs[0].context?.headers).toEqual({
        Authorization: '[REDACTED]',
      });
    });
  });

  describe('logResponse', () => {
    it('should log incoming response', () => {
      requestLogger.logResponse('req-1', {
        status: 200,
        statusText: 'OK',
        duration: 150,
      });

      expect(logs).toHaveLength(1);
      expect(logs[0].message).toContain('200');
      expect(logs[0].message).toContain('(150ms)');
    });
  });

  describe('logError', () => {
    it('should log request error', () => {
      const error = new Error('Connection failed');
      requestLogger.logError('req-1', error, 500);

      expect(logs).toHaveLength(1);
      expect(logs[0].level).toBe(LogLevel.ERROR);
      expect(logs[0].error).toBe(error);
    });
  });

  describe('startTimer', () => {
    it('should create timer function', async () => {
      const getElapsed = requestLogger.startTimer();
      await new Promise((resolve) => setTimeout(resolve, 10));
      const elapsed = getElapsed();

      expect(elapsed).toBeGreaterThanOrEqual(10);
    });
  });
});

describe('PerformanceLogger', () => {
  let logs: LogEntry[];
  let perfLogger: PerformanceLogger;

  beforeEach(() => {
    logs = [];
    const logger = new Logger({
      level: LogLevel.DEBUG,
      transport: createArrayTransport(logs),
    });
    perfLogger = new PerformanceLogger(logger);
  });

  describe('start/end', () => {
    it('should track operation duration', async () => {
      perfLogger.start('op-1', 'Test operation');
      await new Promise((resolve) => setTimeout(resolve, 10));
      const duration = perfLogger.end('op-1', 'Test operation');

      expect(duration).toBeGreaterThanOrEqual(10);
      expect(logs).toHaveLength(2);
    });

    it('should return undefined for unknown timer', () => {
      const duration = perfLogger.end('unknown');
      expect(duration).toBeUndefined();
    });
  });

  describe('measure', () => {
    it('should measure async operation', async () => {
      const result = await perfLogger.measure(
        'op-1',
        async () => {
          await new Promise((resolve) => setTimeout(resolve, 10));
          return 'result';
        },
        'Async op'
      );

      expect(result).toBe('result');
      expect(logs).toHaveLength(2);
    });

    it('should handle errors and log them', async () => {
      await expect(
        perfLogger.measure(
          'op-1',
          async () => {
            throw new Error('Operation failed');
          },
          'Failed op'
        )
      ).rejects.toThrow('Operation failed');

      expect(logs.some((l) => l.level === LogLevel.ERROR)).toBe(true);
    });
  });
});

describe('global logger', () => {
  it('should get global logger', () => {
    const logger = getGlobalLogger();
    expect(logger).toBeInstanceOf(Logger);
  });

  it('should set global logger', () => {
    const custom = new Logger({ level: LogLevel.ERROR });
    setGlobalLogger(custom);

    const global = getGlobalLogger();
    expect(global.getLevel()).toBe(LogLevel.ERROR);

    // Reset
    setGlobalLogger(new Logger());
  });
});

describe('parseLogLevel', () => {
  it('should parse valid level names', () => {
    expect(parseLogLevel('trace')).toBe(LogLevel.TRACE);
    expect(parseLogLevel('DEBUG')).toBe(LogLevel.DEBUG);
    expect(parseLogLevel('Info')).toBe(LogLevel.INFO);
    expect(parseLogLevel('WARN')).toBe(LogLevel.WARN);
    expect(parseLogLevel('error')).toBe(LogLevel.ERROR);
    expect(parseLogLevel('FATAL')).toBe(LogLevel.FATAL);
    expect(parseLogLevel('silent')).toBe(LogLevel.SILENT);
  });

  it('should default to INFO for invalid levels', () => {
    expect(parseLogLevel('invalid')).toBe(LogLevel.INFO);
    expect(parseLogLevel('')).toBe(LogLevel.INFO);
  });
});

describe('createLogger', () => {
  it('should create logger with config', () => {
    const logger = createLogger({ level: LogLevel.DEBUG });
    expect(logger.getLevel()).toBe(LogLevel.DEBUG);
  });
});