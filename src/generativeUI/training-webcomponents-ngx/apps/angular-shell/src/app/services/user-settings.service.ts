import { Injectable, signal } from '@angular/core';

export type UserMode = 'novice' | 'intermediate' | 'expert';

const STORAGE_KEY = 'tc_user_mode';
const LANG_TOGGLE_KEY = 'tc_show_language_options';

function readStoredMode(): UserMode {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === 'intermediate' || stored === 'expert') return stored;
  return 'novice';
}

function readStoredLanguageToggle(): boolean {
  const stored = localStorage.getItem(LANG_TOGGLE_KEY);
  return stored !== 'false'; // default to true
}

@Injectable({
  providedIn: 'root',
})
export class UserSettingsService {
  readonly mode = signal<UserMode>(readStoredMode());
  readonly showLanguageOptions = signal<boolean>(readStoredLanguageToggle());

  setMode(m: UserMode): void {
    localStorage.setItem(STORAGE_KEY, m);
    this.mode.set(m);
  }

  setShowLanguageOptions(show: boolean): void {
    localStorage.setItem(LANG_TOGGLE_KEY, show ? 'true' : 'false');
    this.showLanguageOptions.set(show);
  }
}
