/**
 * NucleusConsole Service
 *
 * Angular wrapper for structured logging, performance monitoring, and analytics.
 * Wraps NucleusConsole from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import type { LogEntry, LogLevel, LogContext, PerformanceMark, PerformanceMeasure } from '../types/builtins.types';

@Injectable()
export class NucleusConsoleService {
  private readonly buffer: LogEntry[] = [];
  private context: LogContext = {};
  private marks = new Map<string, PerformanceMark>();
  private measures: PerformanceMeasure[] = [];

  private readonly logs$ = new BehaviorSubject<LogEntry[]>([]);

  get logEntries$(): Observable<LogEntry[]> {
    return this.logs$.asObservable();
  }

  // -- Logging ---------------------------------------------------------------

  debug(message: string, context?: LogContext): void {
    this.log('debug', message, context);
  }

  info(message: string, context?: LogContext): void {
    this.log('info', message, context);
  }

  warn(message: string, context?: LogContext): void {
    this.log('warn', message, context);
  }

  error(message: string, context?: LogContext): void {
    this.log('error', message, context);
  }

  assert(condition: boolean, message: string): void {
    if (!condition) {
      this.error(`Assertion failed: ${message}`);
    }
  }

  // -- Context ---------------------------------------------------------------

  setContext(ctx: LogContext): void {
    this.context = { ...this.context, ...ctx };
  }

  clearContext(): void {
    this.context = {};
  }

  // -- Performance -----------------------------------------------------------

  mark(name: string): void {
    this.marks.set(name, { name, timestamp: performance.now() });
  }

  measure(name: string, startMark: string, endMark: string): PerformanceMeasure | null {
    const start = this.marks.get(startMark);
    const end = this.marks.get(endMark);
    if (!start || !end) return null;

    const m: PerformanceMeasure = {
      name,
      startMark,
      endMark,
      duration: end.timestamp - start.timestamp,
    };
    this.measures.push(m);
    return m;
  }

  getMeasures(): PerformanceMeasure[] {
    return [...this.measures];
  }

  // -- Buffer ----------------------------------------------------------------

  getBuffer(): LogEntry[] {
    return [...this.buffer];
  }

  clearBuffer(): void {
    this.buffer.length = 0;
    this.logs$.next([]);
  }

  // -- Private ---------------------------------------------------------------

  private log(level: LogLevel, message: string, extra?: LogContext): void {
    const entry: LogEntry = {
      level,
      message,
      timestamp: new Date().toISOString(),
      context: { ...this.context, ...extra },
    };
    this.buffer.push(entry);
    this.logs$.next([...this.buffer]);
  }

  destroy(): void {
    this.logs$.complete();
  }
}
