/**
 * Calendar Enums
 *
 * Re-exports shared enums from the package SDK bundle (single source of truth).
 * CalendarReminderReferenceType, CalendarReminderMeasureType, CalendarTaskUserRoleType,
 * CalendarTaskWorkFileType, CalendarEventRecurrenceType, CalendarProcessPriority
 * are NGX-only extras — kept below.
 */
export { CalendarTaskType, CalendarTaskStatus } from '@sap-oss/sac-sdk';

/** Calendar reminder reference type */
export enum CalendarReminderReferenceType {
  Start = 'Start',
  End = 'End',
  Due = 'Due',
}

/** Calendar reminder measure type */
export enum CalendarReminderMeasureType {
  Minutes = 'Minutes',
  Hours = 'Hours',
  Days = 'Days',
  Weeks = 'Weeks',
}

/** Calendar task user role type */
export enum CalendarTaskUserRoleType {
  Owner = 'Owner',
  Reviewer = 'Reviewer',
  Assignee = 'Assignee',
  Watcher = 'Watcher',
}

/** Calendar task work file type */
export enum CalendarTaskWorkFileType {
  Story = 'Story',
  Application = 'Application',
  Model = 'Model',
  URL = 'URL',
}

/** Calendar event recurrence type */
export enum CalendarEventRecurrenceType {
  None = 'None',
  Daily = 'Daily',
  Weekly = 'Weekly',
  Monthly = 'Monthly',
  Yearly = 'Yearly',
}

/** Calendar process priority */
export enum CalendarProcessPriority {
  Low = 'Low',
  Medium = 'Medium',
  High = 'High',
  Critical = 'Critical',
}
