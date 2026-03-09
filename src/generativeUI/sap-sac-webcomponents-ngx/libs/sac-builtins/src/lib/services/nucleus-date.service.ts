/**
 * NucleusDate Service
 *
 * Angular wrapper for date/time manipulation, timezone conversion,
 * and fiscal calendar support.
 * Wraps NucleusDate from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';

import type { FiscalCalendarConfig, DateRange } from '../types/builtins.types';

@Injectable()
export class NucleusDateService {
  // -- Arithmetic ------------------------------------------------------------

  addDays(isoString: string, days: number): string {
    const d = new Date(isoString);
    d.setDate(d.getDate() + days);
    return d.toISOString();
  }

  addMonths(isoString: string, months: number): string {
    const d = new Date(isoString);
    d.setMonth(d.getMonth() + months);
    return d.toISOString();
  }

  addYears(isoString: string, years: number): string {
    const d = new Date(isoString);
    d.setFullYear(d.getFullYear() + years);
    return d.toISOString();
  }

  diffDays(a: string, b: string): number {
    const ms = new Date(b).getTime() - new Date(a).getTime();
    return Math.round(ms / 86_400_000);
  }

  // -- Component extraction --------------------------------------------------

  getYear(isoString: string): number {
    return new Date(isoString).getFullYear();
  }

  getMonth(isoString: string): number {
    return new Date(isoString).getMonth() + 1;
  }

  getDay(isoString: string): number {
    return new Date(isoString).getDate();
  }

  getDayOfWeek(isoString: string): number {
    return new Date(isoString).getDay();
  }

  getWeekOfYear(isoString: string): number {
    const d = new Date(isoString);
    const start = new Date(d.getFullYear(), 0, 1);
    const diff = d.getTime() - start.getTime() + (start.getTimezoneOffset() - d.getTimezoneOffset()) * 60_000;
    return Math.ceil((diff / 86_400_000 + start.getDay() + 1) / 7);
  }

  // -- Formatting ------------------------------------------------------------

  format(isoString: string, pattern: string): string {
    const d = new Date(isoString);
    return pattern
      .replace('YYYY', String(d.getFullYear()))
      .replace('MM', String(d.getMonth() + 1).padStart(2, '0'))
      .replace('DD', String(d.getDate()).padStart(2, '0'))
      .replace('HH', String(d.getHours()).padStart(2, '0'))
      .replace('mm', String(d.getMinutes()).padStart(2, '0'))
      .replace('ss', String(d.getSeconds()).padStart(2, '0'));
  }

  // -- Timezone --------------------------------------------------------------

  toTimezone(isoString: string, tz: string): string {
    const d = new Date(isoString);
    return d.toLocaleString('en-US', { timeZone: tz });
  }

  // -- Fiscal calendar -------------------------------------------------------

  getFiscalYear(isoString: string, config: FiscalCalendarConfig): number {
    const d = new Date(isoString);
    const month = d.getMonth() + 1;
    return month >= config.startMonth ? d.getFullYear() + 1 : d.getFullYear();
  }

  getFiscalPeriod(isoString: string, config: FiscalCalendarConfig): number {
    const d = new Date(isoString);
    const month = d.getMonth() + 1;
    const offset = month >= config.startMonth ? month - config.startMonth : month + (12 - config.startMonth);
    return Math.floor(offset / (12 / config.periodsPerYear)) + 1;
  }

  // -- Range -----------------------------------------------------------------

  isInRange(isoString: string, range: DateRange): boolean {
    const t = new Date(isoString).getTime();
    return t >= new Date(range.start).getTime() && t <= new Date(range.end).getTime();
  }

  // -- Comparison ------------------------------------------------------------

  isBefore(a: string, b: string): boolean {
    return new Date(a).getTime() < new Date(b).getTime();
  }

  isAfter(a: string, b: string): boolean {
    return new Date(a).getTime() > new Date(b).getTime();
  }

  isSameDay(a: string, b: string): boolean {
    const da = new Date(a);
    const db = new Date(b);
    return da.getFullYear() === db.getFullYear()
      && da.getMonth() === db.getMonth()
      && da.getDate() === db.getDate();
  }
}
