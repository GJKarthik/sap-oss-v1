import { Component, ChangeDetectionStrategy, inject, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { AppStore } from '../../../store/app.store';
import { MODE_CONFIG } from '../../utils/mode.config';
import type { AppMode } from '../../utils/mode.types';

@Component({
  selector: 'app-mode-switcher',
  standalone: true,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="mode-switcher" role="tablist" aria-label="Interaction mode"
         (keydown)="onKeydown($event)">
      @for (mode of modes; track mode.key) {
        <button class="mode-pill"
          role="tab"
          [attr.aria-selected]="activeMode() === mode.key"
          [class.mode-pill--active]="activeMode() === mode.key"
          [attr.tabindex]="activeMode() === mode.key ? 0 : -1"
          (click)="selectMode(mode.key)">
          <ui5-icon [name]="mode.icon" class="mode-icon"></ui5-icon>
          {{ mode.label }}
        </button>
      }
    </div>
  `,
  styles: [`
    .mode-switcher {
      display: flex;
      background: var(--sapShell_Background, rgba(255, 255, 255, 0.06));
      border-radius: 0.5rem;
      padding: 0.1875rem;
      border: 1px solid var(--sapShell_BorderColor, rgba(255, 255, 255, 0.1));
      gap: 0;
    }

    .mode-pill {
      display: flex;
      align-items: center;
      gap: 0.3125rem;
      padding: 0.375rem 0.875rem;
      border-radius: 0.375rem;
      border: none;
      background: transparent;
      color: var(--sapShell_TextColor, rgba(255, 255, 255, 0.5));
      font-size: 0.75rem;
      font-weight: 500;
      cursor: pointer;
      transition: all 200ms ease;
      white-space: nowrap;
    }

    .mode-pill:hover:not(.mode-pill--active) {
      color: var(--sapShell_InteractiveTextColor, rgba(255, 255, 255, 0.8));
      background: var(--sapShell_Hover_Background, rgba(255, 255, 255, 0.04));
    }

    .mode-pill--active {
      background: var(--sapContent_Selected_Background, linear-gradient(135deg, #0a6ed1, #1a8fff));
      color: var(--sapContent_Selected_TextColor, white);
      font-weight: 600;
      box-shadow: 0 2px 8px rgba(10, 110, 209, 0.4);
    }

    .mode-icon {
      font-size: 0.8125rem;
    }
  `],
})
export class ModeSwitcherComponent {
  private readonly store = inject(AppStore);

  readonly activeMode = this.store.activeMode;

  readonly modes: { key: AppMode; label: string; icon: string }[] = [
    { key: 'chat', label: MODE_CONFIG.chat.label, icon: MODE_CONFIG.chat.icon },
    { key: 'cowork', label: MODE_CONFIG.cowork.label, icon: MODE_CONFIG.cowork.icon },
    { key: 'training', label: MODE_CONFIG.training.label, icon: MODE_CONFIG.training.icon },
  ];

  selectMode(mode: AppMode): void {
    this.store.setMode(mode);
  }

  onKeydown(event: KeyboardEvent): void {
    const currentIndex = this.modes.findIndex(m => m.key === this.activeMode());
    let nextIndex = currentIndex;

    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      nextIndex = (currentIndex + 1) % this.modes.length;
      event.preventDefault();
    } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      nextIndex = (currentIndex - 1 + this.modes.length) % this.modes.length;
      event.preventDefault();
    }

    if (nextIndex !== currentIndex) {
      this.selectMode(this.modes[nextIndex].key);
    }
  }
}
