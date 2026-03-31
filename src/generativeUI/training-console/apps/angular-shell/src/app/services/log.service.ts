import { Injectable, isDevMode } from '@angular/core';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  level: LogLevel;
  message: string;
  context?: string;
  timestamp: string;
  data?: unknown;
}

/**
 * Structured JSON logger for the Training Console.
 * In production, emits newline-delimited JSON to the console so log
 * aggregation tools (Cloud Logging, Loki, etc.) can parse entries directly.
 * In development, emits coloured human-readable output.
 */
@Injectable({ providedIn: 'root' })
export class LogService {
  private readonly isDev = isDevMode();

  debug(message: string, context?: string, data?: unknown): void {
    this.emit('debug', message, context, data);
  }

  info(message: string, context?: string, data?: unknown): void {
    this.emit('info', message, context, data);
  }

  warn(message: string, context?: string, data?: unknown): void {
    this.emit('warn', message, context, data);
  }

  error(message: string, context?: string, data?: unknown): void {
    this.emit('error', message, context, data);
  }

  private emit(level: LogLevel, message: string, context?: string, data?: unknown): void {
    const entry: LogEntry = {
      level,
      message,
      ...(context ? { context } : {}),
      timestamp: new Date().toISOString(),
      ...(data !== undefined ? { data } : {}),
    };

    if (this.isDev) {
      this.devLog(entry);
    } else {
      this.prodLog(entry);
    }
  }

  private devLog(entry: LogEntry): void {
    const prefix = `[${entry.timestamp}] [${entry.level.toUpperCase()}]${entry.context ? ` [${entry.context}]` : ''}`;
    switch (entry.level) {
      case 'debug': console.debug(prefix, entry.message, entry.data ?? ''); break;
      case 'info':  console.info(prefix, entry.message, entry.data ?? '');  break;
      case 'warn':  console.warn(prefix, entry.message, entry.data ?? '');  break;
      case 'error': console.error(prefix, entry.message, entry.data ?? ''); break;
    }
  }

  private prodLog(entry: LogEntry): void {
    const line = JSON.stringify(entry);
    switch (entry.level) {
      case 'debug': console.debug(line); break;
      case 'info':  console.info(line);  break;
      case 'warn':  console.warn(line);  break;
      case 'error': console.error(line); break;
    }
  }
}
