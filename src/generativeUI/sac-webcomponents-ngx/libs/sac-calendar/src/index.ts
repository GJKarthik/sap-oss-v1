/**
 * @sap-oss/sac-webcomponents-ngx/calendar
 *
 * Angular Calendar Module for SAP Analytics Cloud.
 * Covers: CalendarService, CalendarTask, CalendarEvent,
 *         CalendarProcess, CalendarReminder, CalendarFilter.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacCalendarModule } from './lib/sac-calendar.module';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacCalendarService } from './lib/services/sac-calendar.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  CalendarTask,
  CalendarTaskStatus,
  CalendarEvent,
  CalendarRecurrence,
  CalendarProcess,
  CalendarReminder,
  CalendarFilter,
  CalendarEvents,
} from './lib/types/calendar.types';
