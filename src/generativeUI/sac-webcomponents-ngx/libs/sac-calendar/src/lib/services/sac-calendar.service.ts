/**
 * SAC Calendar Service
 *
 * Angular wrapper for calendar task, event, process, and reminder management.
 * Wraps CalendarService from sap-sac-webcomponents-ts/src/calendar.
 */

import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';
import { SacApiService } from '@sap-oss/sac-ngx-core';

import type {
  CalendarTask,
  CalendarEvent,
  CalendarProcess,
  CalendarReminder,
  CalendarFilter,
} from '../types/calendar.types';

@Injectable()
export class SacCalendarService {
  private readonly api = inject(SacApiService);
  private readonly tasks$ = new BehaviorSubject<CalendarTask[]>([]);
  private readonly events$ = new BehaviorSubject<CalendarEvent[]>([]);
  private readonly processes$ = new BehaviorSubject<CalendarProcess[]>([]);
  private readonly reminders$ = new BehaviorSubject<CalendarReminder[]>([]);
  private readonly loading$ = new BehaviorSubject<boolean>(false);

  get currentTasks$(): Observable<CalendarTask[]> {
    return this.tasks$.asObservable();
  }

  get currentEvents$(): Observable<CalendarEvent[]> {
    return this.events$.asObservable();
  }

  get currentProcesses$(): Observable<CalendarProcess[]> {
    return this.processes$.asObservable();
  }

  get currentReminders$(): Observable<CalendarReminder[]> {
    return this.reminders$.asObservable();
  }

  get isLoading$(): Observable<boolean> {
    return this.loading$.asObservable();
  }

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  async getTasks(filter?: CalendarFilter): Promise<CalendarTask[]> {
    this.loading$.next(true);
    try {
      const filterParams = filter ? '?' + new URLSearchParams(filter as Record<string, string>).toString() : '';
      const tasks = await this.api.get<CalendarTask[]>('/calendar/tasks' + filterParams);
      this.tasks$.next(tasks);
      return tasks;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    } finally {
      this.loading$.next(false);
    }
  }

  async createTask(task: Omit<CalendarTask, 'id'>): Promise<CalendarTask> {
    try {
      const newTask = await this.api.post<CalendarTask>('/calendar/tasks', task);
      this.tasks$.next([...this.tasks$.value, newTask]);
      return newTask;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async updateTask(taskId: string, updates: Partial<CalendarTask>): Promise<CalendarTask | null> {
    try {
      const updated = await this.api.put<CalendarTask>('/calendar/tasks/' + taskId, updates);
      const tasks = this.tasks$.value.map(t => t.id === taskId ? updated : t);
      this.tasks$.next(tasks);
      return updated;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async deleteTask(taskId: string): Promise<boolean> {
    try {
      await this.api.delete('/calendar/tasks/' + taskId);
      const tasks = this.tasks$.value.filter(t => t.id !== taskId);
      this.tasks$.next(tasks);
      return true;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  async getEvents(filter?: CalendarFilter): Promise<CalendarEvent[]> {
    this.loading$.next(true);
    try {
      const filterParams = filter ? '?' + new URLSearchParams(filter as Record<string, string>).toString() : '';
      const events = await this.api.get<CalendarEvent[]>('/calendar/events' + filterParams);
      this.events$.next(events);
      return events;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    } finally {
      this.loading$.next(false);
    }
  }

  async createEvent(event: Omit<CalendarEvent, 'id'>): Promise<CalendarEvent> {
    try {
      const newEvent = await this.api.post<CalendarEvent>('/calendar/events', event);
      this.events$.next([...this.events$.value, newEvent]);
      return newEvent;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async updateEvent(eventId: string, updates: Partial<CalendarEvent>): Promise<CalendarEvent | null> {
    try {
      const updated = await this.api.put<CalendarEvent>('/calendar/events/' + eventId, updates);
      const events = this.events$.value.map(ev => ev.id === eventId ? updated : ev);
      this.events$.next(events);
      return updated;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async deleteEvent(eventId: string): Promise<boolean> {
    try {
      await this.api.delete('/calendar/events/' + eventId);
      const events = this.events$.value.filter(e => e.id !== eventId);
      this.events$.next(events);
      return true;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Processes
  // ---------------------------------------------------------------------------

  async getProcesses(): Promise<CalendarProcess[]> {
    try {
      const processes = await this.api.get<CalendarProcess[]>('/calendar/processes');
      this.processes$.next(processes);
      return processes;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async createProcess(process: Omit<CalendarProcess, 'id'>): Promise<CalendarProcess> {
    try {
      const newProcess = await this.api.post<CalendarProcess>('/calendar/processes', process);
      this.processes$.next([...this.processes$.value, newProcess]);
      return newProcess;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async updateProcess(processId: string, updates: Partial<CalendarProcess>): Promise<CalendarProcess | null> {
    try {
      const updated = await this.api.put<CalendarProcess>('/calendar/processes/' + processId, updates);
      const processes = this.processes$.value.map(p => p.id === processId ? updated : p);
      this.processes$.next(processes);
      return updated;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Reminders
  // ---------------------------------------------------------------------------

  async getReminders(): Promise<CalendarReminder[]> {
    try {
      const reminders = await this.api.get<CalendarReminder[]>('/calendar/reminders');
      this.reminders$.next(reminders);
      return reminders;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async createReminder(reminder: Omit<CalendarReminder, 'id'>): Promise<CalendarReminder> {
    try {
      const newReminder = await this.api.post<CalendarReminder>('/calendar/reminders', reminder);
      this.reminders$.next([...this.reminders$.value, newReminder]);
      return newReminder;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async dismissReminder(reminderId: string): Promise<boolean> {
    try {
      await this.api.put('/calendar/reminders/' + reminderId + '/dismiss', {});
      const reminders = this.reminders$.value.map(r =>
        r.id === reminderId ? { ...r, dismissed: true } : r
      );
      this.reminders$.next(reminders);
      return true;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async deleteReminder(reminderId: string): Promise<boolean> {
    try {
      await this.api.delete('/calendar/reminders/' + reminderId);
      const reminders = this.reminders$.value.filter(r => r.id !== reminderId);
      this.reminders$.next(reminders);
      return true;
    } catch (e) {
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  destroy(): void {
    this.tasks$.complete();
    this.events$.complete();
    this.processes$.complete();
    this.reminders$.complete();
    this.loading$.complete();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  private generateId(): string {
    return `cal_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
  }
}
