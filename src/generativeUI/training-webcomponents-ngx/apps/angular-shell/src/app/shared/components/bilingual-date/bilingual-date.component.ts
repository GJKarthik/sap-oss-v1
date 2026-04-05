import { Component, ChangeDetectionStrategy, Input, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { I18nService } from '../../services/i18n.service';
import { LocaleDatePipe, LocaleDateFormatStyle } from '../../pipes/locale-date.pipe';

/**
 * A component that displays a date in both Gregorian and Hijri calendars.
 * Especially useful for Arabic locale in Middle Eastern enterprise applications.
 */
@Component({
  selector: 'app-bilingual-date',
  standalone: true,
  imports: [CommonModule, LocaleDatePipe],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="bilingual-date" [class.rtl]="i18n.isRtl()">
      <div class="date-main">
        <span class="calendar-label" *ngIf="showLabels">{{ i18n.t(mainCalendar + 'Label') }}</span>
        <span class="date-value">{{ date | localeDate:style:mainCalendar }}</span>
      </div>
      <div class="date-alt">
        <span class="calendar-label" *ngIf="showLabels">{{ i18n.t(altCalendar + 'Label') }}</span>
        <span class="date-value">{{ date | localeDate:style:altCalendar }}</span>
      </div>
    </div>
  `,
  styles: [`
    .bilingual-date {
      display: flex;
      flex-direction: column;
      gap: 0.125rem;
      font-size: 0.8125rem;
    }
    .date-main {
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
    }
    .date-alt {
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }
    .calendar-label {
      font-size: 0.625rem;
      text-transform: uppercase;
      letter-spacing: 0.02em;
      margin-inline-end: 0.375rem;
      opacity: 0.8;
    }
    .rtl {
      .date-value { direction: rtl; unicode-bidi: embed; }
    }
  `],
})
export class BilingualDateComponent {
  @Input({ required: true }) date!: Date | string | number | null;
  @Input() style: LocaleDateFormatStyle = 'date';
  @Input() showLabels = true;

  readonly i18n = inject(I18nService);

  get mainCalendar(): 'gregorian' | 'hijri' {
    return this.i18n.isRtl() ? 'hijri' : 'gregorian';
  }

  get altCalendar(): 'gregorian' | 'hijri' {
    return this.i18n.isRtl() ? 'gregorian' : 'hijri';
  }
}
