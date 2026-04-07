/**
 * NucleusTimer Service
 *
 * Angular wrapper for timer functionality with start, stop, and onTimeout.
 * Wraps Timer from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { Subject, Observable } from 'rxjs';

import type { TimerEventHandler } from '../types/builtins.types';

interface TimerEntry {
  id: string;
  intervalMs: number;
  repeat: boolean;
  running: boolean;
  handle: ReturnType<typeof setTimeout> | null;
  handler: TimerEventHandler | null;
}

@Injectable()
export class NucleusTimerService implements OnDestroy {
  private timers = new Map<string, TimerEntry>();
  private readonly tick$ = new Subject<string>();

  /** Observable emitting timer ID on each tick */
  get onTick$(): Observable<string> {
    return this.tick$.asObservable();
  }

  /**
   * Create and start a timer.
   */
  start(id: string, intervalMs: number, repeat = false, handler?: TimerEventHandler): void {
    this.stop(id);
    const entry: TimerEntry = { id, intervalMs, repeat, running: true, handle: null, handler: handler ?? null };

    if (repeat) {
      entry.handle = setInterval(() => {
        this.tick$.next(id);
        entry.handler?.();
      }, intervalMs) as unknown as ReturnType<typeof setTimeout>;
    } else {
      entry.handle = setTimeout(() => {
        this.tick$.next(id);
        entry.handler?.();
        entry.running = false;
      }, intervalMs);
    }

    this.timers.set(id, entry);
  }

  /**
   * Stop a running timer.
   */
  stop(id: string): void {
    const entry = this.timers.get(id);
    if (!entry) return;

    if (entry.repeat) {
      clearInterval(entry.handle as unknown as number);
    } else {
      clearTimeout(entry.handle as unknown as number);
    }
    entry.running = false;
    entry.handle = null;
  }

  /**
   * Check if a timer is running.
   */
  isRunning(id: string): boolean {
    return this.timers.get(id)?.running ?? false;
  }

  /**
   * Remove a timer entirely.
   */
  remove(id: string): void {
    this.stop(id);
    this.timers.delete(id);
  }

  ngOnDestroy(): void {
    for (const id of this.timers.keys()) {
      this.stop(id);
    }
    this.timers.clear();
    this.tick$.complete();
  }
}
