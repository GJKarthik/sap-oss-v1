/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Calendar tasks, events, processes, reminders
 *
 * Maps to: sac_widgets.mg / sac_odps_facts.mg CalendarTask enums
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/calendar/ (2 handlers)
 */

import type { SACRestAPIClient } from '../client';
import type { OperationResult, CalendarTaskType, CalendarTaskStatus } from '../types';

// ---------------------------------------------------------------------------
// Calendar types
// ---------------------------------------------------------------------------

export interface CalendarTask {
  id: string;
  title: string;
  description?: string;
  type: CalendarTaskType;
  status: CalendarTaskStatus;
  startDate?: string;
  endDate?: string;
  dueDate?: string;
  assignee?: string;
  priority?: 'low' | 'medium' | 'high';
  parentId?: string;
  dependencies?: string[];
  tags?: string[];
}

export interface CalendarEvent {
  id: string;
  title: string;
  description?: string;
  startDate: string;
  endDate: string;
  allDay?: boolean;
  recurrence?: string;
  location?: string;
}

export interface CalendarProcess {
  id: string;
  name: string;
  description?: string;
  tasks: string[];
  status: CalendarTaskStatus;
  owner?: string;
  startDate?: string;
  endDate?: string;
}

export interface CalendarReminder {
  id: string;
  taskId: string;
  reminderDate: string;
  message?: string;
  sent?: boolean;
}

export interface CalendarFilter {
  status?: CalendarTaskStatus[];
  type?: CalendarTaskType[];
  assignee?: string;
  startDate?: string;
  endDate?: string;
  tags?: string[];
}

// ---------------------------------------------------------------------------
// CalendarService
// ---------------------------------------------------------------------------

export class CalendarService {
  constructor(private readonly client: SACRestAPIClient) {}

  // -- Tasks -----------------------------------------------------------------

  async getTasks(filter?: CalendarFilter): Promise<CalendarTask[]> {
    return this.client.post<CalendarTask[]>('/calendar/tasks', filter ?? {});
  }

  async getTask(taskId: string): Promise<CalendarTask> {
    return this.client.get<CalendarTask>(`/calendar/tasks/${e(taskId)}`);
  }

  async createTask(task: Omit<CalendarTask, 'id'>): Promise<CalendarTask> {
    return this.client.post<CalendarTask>('/calendar/tasks/create', task);
  }

  async updateTask(taskId: string, updates: Partial<CalendarTask>): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/calendar/tasks/${e(taskId)}`, updates);
  }

  async deleteTask(taskId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/calendar/tasks/${e(taskId)}`);
  }

  async setTaskStatus(taskId: string, status: CalendarTaskStatus): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/calendar/tasks/${e(taskId)}/status`, { status });
  }

  async addDependency(taskId: string, dependsOnId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/calendar/tasks/${e(taskId)}/dependencies`, { dependsOnId });
  }

  async removeDependency(taskId: string, dependsOnId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/calendar/tasks/${e(taskId)}/dependencies/${e(dependsOnId)}`);
  }

  // -- Events ----------------------------------------------------------------

  async getEvents(startDate: string, endDate: string): Promise<CalendarEvent[]> {
    return this.client.post<CalendarEvent[]>('/calendar/events', { startDate, endDate });
  }

  async createEvent(event: Omit<CalendarEvent, 'id'>): Promise<CalendarEvent> {
    return this.client.post<CalendarEvent>('/calendar/events/create', event);
  }

  async updateEvent(eventId: string, updates: Partial<CalendarEvent>): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/calendar/events/${e(eventId)}`, updates);
  }

  async deleteEvent(eventId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/calendar/events/${e(eventId)}`);
  }

  // -- Processes --------------------------------------------------------------

  async getProcesses(): Promise<CalendarProcess[]> {
    return this.client.get<CalendarProcess[]>('/calendar/processes');
  }

  async getProcess(processId: string): Promise<CalendarProcess> {
    return this.client.get<CalendarProcess>(`/calendar/processes/${e(processId)}`);
  }

  async createProcess(process: Omit<CalendarProcess, 'id'>): Promise<CalendarProcess> {
    return this.client.post<CalendarProcess>('/calendar/processes/create', process);
  }

  // -- Reminders --------------------------------------------------------------

  async getReminders(taskId: string): Promise<CalendarReminder[]> {
    return this.client.get<CalendarReminder[]>(`/calendar/tasks/${e(taskId)}/reminders`);
  }

  async createReminder(taskId: string, reminderDate: string, message?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/calendar/tasks/${e(taskId)}/reminders`, { reminderDate, message });
  }

  async deleteReminder(taskId: string, reminderId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/calendar/tasks/${e(taskId)}/reminders/${e(reminderId)}`);
  }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface CalendarEvents {
  select: (date: string) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

export type { CalendarTaskType, CalendarTaskStatus } from '../types';
