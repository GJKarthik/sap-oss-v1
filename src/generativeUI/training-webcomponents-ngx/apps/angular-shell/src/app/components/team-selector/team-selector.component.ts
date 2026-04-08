/**
 * Team Selector Component — compact Country × Domain picker for app header.
 *
 * Displays: [🇦🇪 UAE] × [Treasury]
 * Emits context changes that flow through TeamContextService to all consumers.
 */

import { Component, ChangeDetectionStrategy, inject, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { TeamContextService } from '../../services/team-context.service';
import { I18nService } from '../../services/i18n.service';

@Component({
  selector: 'app-team-selector',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="team-selector">
      <label class="team-selector__label">{{ i18n.t('team.context') }}</label>
      <div class="team-selector__controls">
        <!-- Country dropdown -->
        <select
          class="team-selector__select"
          [ngModel]="teamCtx.country()"
          (ngModelChange)="teamCtx.setCountry($event)"
          [attr.aria-label]="i18n.t('team.country')">
          <option value="">{{ i18n.t('team.allCountries') }}</option>
          @for (opt of countryOptions; track opt.code) {
            <option [value]="opt.code">{{ opt.flag }} {{ opt.name }}</option>
          }
        </select>

        <span class="team-selector__separator">×</span>

        <!-- Domain dropdown -->
        <select
          class="team-selector__select"
          [ngModel]="teamCtx.domain()"
          (ngModelChange)="teamCtx.setDomain($event)"
          [attr.aria-label]="i18n.t('team.domain')">
          <option value="">{{ i18n.t('team.allDomains') }}</option>
          @for (opt of domainOptions; track opt.id) {
            <option [value]="opt.id">{{ opt.name }}</option>
          }
        </select>

        @if (!teamCtx.isGlobal()) {
          <button
            class="team-selector__reset"
            (click)="teamCtx.reset()"
            [attr.aria-label]="i18n.t('team.resetToGlobal')"
            title="Reset to global view">
            ✕
          </button>
        }
      </div>
      <span class="team-selector__scope-badge" [attr.data-scope]="teamCtx.scopeLevel()">
        {{ teamCtx.scopeLevel() }}
      </span>
    </div>
  `,
  styles: [`
    .team-selector {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
    }
    .team-selector__label {
      font-weight: 500;
      color: var(--text-secondary, #666);
      white-space: nowrap;
    }
    .team-selector__controls {
      display: flex;
      align-items: center;
      gap: 4px;
    }
    .team-selector__select {
      padding: 4px 8px;
      border: 1px solid var(--border-color, #ddd);
      border-radius: 6px;
      background: var(--surface-color, #fff);
      color: var(--text-primary, #333);
      font-size: 12px;
      cursor: pointer;
      min-width: 120px;
    }
    .team-selector__select:focus {
      outline: 2px solid var(--accent-color, #0070d2);
      outline-offset: -1px;
    }
    .team-selector__separator {
      color: var(--text-tertiary, #999);
      font-weight: 300;
      padding: 0 2px;
    }
    .team-selector__reset {
      background: none;
      border: 1px solid var(--border-color, #ddd);
      border-radius: 50%;
      width: 22px;
      height: 22px;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      font-size: 10px;
      color: var(--text-secondary, #666);
      padding: 0;
    }
    .team-selector__reset:hover {
      background: var(--hover-bg, #f5f5f5);
      color: var(--text-primary, #333);
    }
    .team-selector__scope-badge {
      font-size: 10px;
      padding: 2px 6px;
      border-radius: 4px;
      text-transform: uppercase;
      font-weight: 600;
      letter-spacing: 0.5px;
    }
    .team-selector__scope-badge[data-scope="global"] {
      background: var(--badge-global-bg, #e8f5e9);
      color: var(--badge-global-fg, #2e7d32);
    }
    .team-selector__scope-badge[data-scope="domain"] {
      background: var(--badge-domain-bg, #e3f2fd);
      color: var(--badge-domain-fg, #1565c0);
    }
    .team-selector__scope-badge[data-scope="country"] {
      background: var(--badge-country-bg, #fff3e0);
      color: var(--badge-country-fg, #e65100);
    }
    .team-selector__scope-badge[data-scope="team"] {
      background: var(--badge-team-bg, #fce4ec);
      color: var(--badge-team-fg, #c62828);
    }
  `]
})
export class TeamSelectorComponent {
  readonly teamCtx = inject(TeamContextService);
  readonly i18n = inject(I18nService);

  readonly countryOptions = this.teamCtx.getCountryOptions();
  readonly domainOptions = this.teamCtx.getDomainOptions();
}
