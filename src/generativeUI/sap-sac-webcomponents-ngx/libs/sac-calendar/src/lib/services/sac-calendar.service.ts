/**
 * SAC Calendar Service
 *
 * Angular wrapper for calendar task, event, process, and reminder management.
 * Wraps CalendarService from sap-sac-webcomponents-ts/src/calendar.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import type {
  CalendarTask,
  CalendarEvent,
  CalendarProcess,
  CalendarReminder,
  CalendarFilter,
} from '../types/calendar.types';

@Injectable()
export class SacCalendarService {
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
      // Placeholder — delegates to SAC REST API
      return this.tasks$.value;
    } finally {
      this.loading$.next(false);
    }
  }

  async createTask(task: Omit<CalendarTask, 'id'>): Promise<CalendarTask> {
    const newTask: CalendarTask = { ...task, id: this.generateId() };
    this.tasks$.next([...this.tasks$.value, newTask]);
    return newTask;
  }

  async updateTask(taskId: string, updates: Partial<CalendarTask>): Promise<CalendarTask | null> {
    const tasks = this.tasks$.value;
    const idx = tasks.findIndex(t => t.id === taskId);
    if (idx === -1) return null;
    const updated = { ...tasks[idx], ...updates };
    tasks[idx] = updated;
    this.tasks$.next([...tasks]);
    return updated;
  }

  async deleteTask(taskId: string): Promise<boolean> {
    const tasks = this.tasks$.value.filter(t => t.id !== taskId);
    this.tasks$.next(tasks);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  async getEvents(filter?: CalendarFilter): Promise<CalendarEvent[]> {
    this.loading$.next(true);
    try {
      return this.events$.value;
    } finally {
      this.loading$.next(false);
    }
  }

  async createEvent(event: Omit<CalendarEvent, 'id'>): Promise<CalendarEvent> {
    const newEvent: CalendarEvent = { ...event, id: this.generateId() };
    this.events$.next([...this.events$.value, newEvent]);
    return newEvent;
  }

  async updateEvent(eventId: string, updates: Partial<CalendarEvent>): Promise<CalendarEvent | null> {
    const events = this.events$.value;
    const idx = events.findIndex(e => e.id === eventId);
    if (idx === -1) return null;
    const updated = { ...events[idx], ...updates };
    events[idx] = updated;
    this.events$.next([...events]);
    return updated;
  }

  async deleteEvent(eventId: string): Promise<boolean> {
    const events = this.events$.value.filter(e => e.id !== eventId);
    this.events$.next(events);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Processes
  // ---------------------------------------------------------------------------

  async getProcesses(): Promise<CalendarProcess[]> {
    return this.processes$.value;
  }

  async createProcess(process: Omit<CalendarProcess, 'id'>): Promise<CalendarProcess> {
    const newProcess: CalendarProcess = { ...process, id: this.generateId() };
    this.processes$.next([...this.processes$.value, newProcess]);
    return newProcess;
  }

  async updateProcess(processId: string, updates: Partial<CalendarProcess>): Promise<CalendarProcess | null> {
    const processes = this.processes$.value;
    const idx = processes.findIndex(p => p.id === processId);
    if (idx === -1) return null;
    const updated = { ...processes[idx], ...updates };
    processes[idx] = updated;
    this.processes$.next([...processes]);
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Reminders
  // ---------------------------------------------------------------------------

  async getReminders(): Promise<CalendarReminder[]> {
    return this.reminders$.value;
  }

  async createReminder(reminder: Omit<CalendarReminder, 'id'>): Promise<CalendarReminder> {
    const newReminder: CalendarReminder = { ...reminder, id: this.generateId() };
    this.reminders$.next([...this.reminders$.value, newReminder]);
    return newReminder;
  }

  async dismissReminder(reminderId: string): Promise<boolean> {
    const reminders = this.reminders$.value;
    const idx = reminders.findIndex(r => r.id === reminderId);
    if (idx === -1) return false;
    reminders[idx] = { ...reminders[idx], dismissed: true };
    this.reminders$.next([...reminders]);
    return true;
  }

  async deleteReminder(reminderId: string): Promise<boolean> {
    const reminders = this.reminders$.value.filter(r => r.id !== reminderId);
    this.reminders$.next(reminders);
    return true;
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
