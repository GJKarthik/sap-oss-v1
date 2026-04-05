import { Injectable, signal } from '@angular/core';

export type UserMode = 'novice' | 'intermediate' | 'expert';
export type CalendarType = 'gregorian' | 'hijri';
export type NumberingSystem = 'latn' | 'arab';

const MODE_KEY = 'tc_user_mode';
const CALENDAR_KEY = 'tc_calendar_type';
const NUMBERING_KEY = 'tc_numbering_system';

function readStoredMode(): UserMode {
  const stored = localStorage.getItem(MODE_KEY);
  if (stored === 'intermediate' || stored === 'expert') return stored;
  return 'novice';
}

function readStoredCalendar(): CalendarType {
  const stored = localStorage.getItem(CALENDAR_KEY);
  return stored === 'hijri' ? 'hijri' : 'gregorian';
}

function readStoredNumbering(): NumberingSystem {
  const stored = localStorage.getItem(NUMBERING_KEY);
  return stored === 'arab' ? 'arab' : 'latn';
}

@Injectable({
  providedIn: 'root',
})
export class UserSettingsService {
  readonly mode = signal<UserMode>(readStoredMode());
  readonly calendar = signal<CalendarType>(readStoredCalendar());
  readonly numbering = signal<NumberingSystem>(readStoredNumbering());

  setMode(m: UserMode): void {
    localStorage.setItem(MODE_KEY, m);
    this.mode.set(m);
  }

  setCalendar(c: CalendarType): void {
    localStorage.setItem(CALENDAR_KEY, c);
    this.calendar.set(c);
  }

  setNumbering(n: NumberingSystem): void {
    localStorage.setItem(NUMBERING_KEY, n);
    this.numbering.set(n);
  }
}
