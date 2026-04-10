import {
  Component,
  ChangeDetectionStrategy,
  CUSTOM_ELEMENTS_SCHEMA,
  inject,
  computed,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { AppStore } from '../../../store/app.store';
import { I18nService } from '../../../services/i18n.service';
import { AppMode } from '../../utils/mode.types';
import { ALL_MODES, MODE_CONFIG } from '../../utils/mode.config';
import { nextMode, prevMode } from '../../utils/mode.helpers';

@Component({
  selector: 'app-mode-switcher',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div
      class="mode-switcher"
      role="tablist"
      [attr.aria-label]="i18n.t('mode.switcherLabel')"
      (keydown)="onKeydown($event)">
      @for (mode of modes; track mode.id) {
        <button
          class="mode-switcher__tab"
          role="tab"
          [class.mode-switcher__tab--active]="store.activeMode() === mode.id"
          [attr.aria-selected]="store.activeMode() === mode.id"
          [attr.tabindex]="store.activeMode() === mode.id ? 0 : -1"
          (click)="selectMode(mode.id)">
          <ui5-icon [name]="mode.icon" class="mode-switcher__icon"></ui5-icon>
          <span class="mode-switcher__label">{{ i18n.t(mode.labelKey) }}</span>
        </button>
      }
      <div
        class="mode-switcher__indicator"
        [style.transform]="indicatorTransform()">
      </div>
    </div>
  `,
  styles: [`
    .mode-switcher {
      display: flex;
      position: relative;
      background: rgba(255, 255, 255, 0.08);
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
      border-radius: 0.625rem;
      padding: 0.125rem;
      gap: 0.125rem;
      border: 0.5px solid rgba(255, 255, 255, 0.12);
    }

    .mode-switcher__tab {
      display: flex;
      align-items: center;
      gap: 0.375rem;
      padding: 0.3125rem 0.75rem;
      border: none;
      background: transparent;
      color: var(--sapTextColor, #32363a);
      font-family: inherit;
      font-size: 0.8125rem;
      font-weight: 500;
      cursor: pointer;
      border-radius: 0.5rem;
      position: relative;
      z-index: 1;
      transition: color 0.25s ease, opacity 0.25s ease;
      opacity: 0.6;
      white-space: nowrap;
    }

    .mode-switcher__tab:hover { opacity: 0.85; }
    .mode-switcher__tab:active { transform: scale(0.97); }
    .mode-switcher__tab:focus-visible {
      outline: 2px solid var(--sapBrandColor, #0071e3);
      outline-offset: 1px;
    }

    .mode-switcher__tab--active {
      opacity: 1;
      font-weight: 600;
    }

    .mode-switcher__icon { font-size: 0.875rem; }

    .mode-switcher__indicator {
      position: absolute;
      top: 0.125rem;
      left: 0.125rem;
      width: calc(33.333% - 0.167rem);
      height: calc(100% - 0.25rem);
      background: rgba(255, 255, 255, 0.15);
      border-radius: 0.5rem;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
      transition: transform 0.35s cubic-bezier(0.34, 1.56, 0.64, 1);
      pointer-events: none;
    }
  `],
})
export class ModeSwitcherComponent {
  readonly store = inject(AppStore);
  readonly i18n = inject(I18nService);

  readonly modes = ALL_MODES.map(id => MODE_CONFIG[id]);

  readonly indicatorTransform = computed(() => {
    const idx = ALL_MODES.indexOf(this.store.activeMode());
    return `translateX(${idx * 100}%)`;
  });

  selectMode(mode: AppMode): void {
    this.store.setMode(mode);
  }

  onKeydown(event: KeyboardEvent): void {
    const current = this.store.activeMode();
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      event.preventDefault();
      this.store.setMode(nextMode(current));
    } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      event.preventDefault();
      this.store.setMode(prevMode(current));
    }
  }
}
