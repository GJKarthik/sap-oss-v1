import { Injectable, signal } from '@angular/core';

export type UserMode = 'novice' | 'intermediate' | 'expert';

@Injectable({
  providedIn: 'root'
})
export class UserSettingsService {
  readonly mode = signal<UserMode>('novice');

  setMode(m: UserMode): void {
    this.mode.set(m);
  }
}
