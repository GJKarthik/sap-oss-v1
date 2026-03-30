import { Injectable, signal } from '@angular/core';

export type UserMode = 'novice' | 'intermediate' | 'expert';

const STORAGE_KEY = 'tc_user_mode';

function readStoredMode(): UserMode {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === 'intermediate' || stored === 'expert') return stored;
  return 'novice';
}

@Injectable({
  providedIn: 'root',
})
export class UserSettingsService {
  readonly mode = signal<UserMode>(readStoredMode());

  setMode(m: UserMode): void {
    localStorage.setItem(STORAGE_KEY, m);
    this.mode.set(m);
  }
}
