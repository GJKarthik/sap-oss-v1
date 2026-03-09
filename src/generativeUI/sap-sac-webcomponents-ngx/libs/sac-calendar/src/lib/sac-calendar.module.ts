/**
 * SAC Calendar Module
 *
 * Angular module for SAC calendar features: tasks, events, processes, reminders.
 * Service-only module — no components.
 */

import { NgModule } from '@angular/core';

import { SacCalendarService } from './services/sac-calendar.service';

@NgModule({
  providers: [SacCalendarService],
})
export class SacCalendarModule {}
