/**
 * Calendar types — from sap-sac-webcomponents-ts/src/calendar
 */

export interface CalendarTask {
  id: string;
  title: string;
  description?: string;
  status: CalendarTaskStatus;
  assignee?: string;
  dueDate?: string;
  priority?: 'low' | 'medium' | 'high';
  tags?: string[];
}

export type CalendarTaskStatus = 'open' | 'in_progress' | 'completed' | 'cancelled';

export interface CalendarEvent {
  id: string;
  title: string;
  description?: string;
  startDate: string;
  endDate: string;
  allDay?: boolean;
  recurrence?: CalendarRecurrence;
  participants?: string[];
}

export interface CalendarRecurrence {
  frequency: 'daily' | 'weekly' | 'monthly' | 'yearly';
  interval?: number;
  endDate?: string;
  count?: number;
}

export interface CalendarProcess {
  id: string;
  name: string;
  description?: string;
  startDate: string;
  endDate: string;
  status: 'draft' | 'active' | 'completed' | 'archived';
  tasks?: CalendarTask[];
}

export interface CalendarReminder {
  id: string;
  taskId?: string;
  eventId?: string;
  message: string;
  triggerDate: string;
  type: 'email' | 'notification' | 'popup';
  dismissed?: boolean;
}

export interface CalendarFilter {
  startDate?: string;
  endDate?: string;
  status?: CalendarTaskStatus[];
  assignee?: string;
  tags?: string[];
  processId?: string;
}

export interface CalendarEvents {
  onTaskCreated?: (task: CalendarTask) => void;
  onTaskUpdated?: (task: CalendarTask) => void;
  onTaskDeleted?: (taskId: string) => void;
  onEventCreated?: (event: CalendarEvent) => void;
  onEventUpdated?: (event: CalendarEvent) => void;
  onEventDeleted?: (eventId: string) => void;
  onProcessCreated?: (process: CalendarProcess) => void;
  onProcessUpdated?: (process: CalendarProcess) => void;
  onReminderTriggered?: (reminder: CalendarReminder) => void;
}
