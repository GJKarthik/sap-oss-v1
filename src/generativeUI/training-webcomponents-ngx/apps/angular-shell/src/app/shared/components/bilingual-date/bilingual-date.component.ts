import { Component, Input, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';

/**
 * Displays a date value in both the Gregorian (en-US) and Hijri (ar-SA) calendars.
 * Falls back gracefully when the Intl.DateTimeFormat Hijri calendar is unavailable.
 */
@Component({
  selector: 'app-bilingual-date',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <span class="bilingual-date">
      <span class="bilingual-date__gregorian" dir="ltr">{{ gregorian }}</span>
      <span class="bilingual-date__sep" aria-hidden="true"> / </span>
      <span class="bilingual-date__hijri" dir="rtl" lang="ar">{{ hijri }}</span>
    </span>
  `,
  styles: [`
    .bilingual-date { display: inline-flex; align-items: center; gap: 0.25rem; font-variant-numeric: tabular-nums; }
    .bilingual-date__hijri { font-family: 'Noto Naskh Arabic', 'Segoe UI', sans-serif; }
  `],
})
export class BilingualDateComponent {
  @Input() set value(v: string | Date | null | undefined) {
    const d = v ? new Date(v) : null;
    if (!d || isNaN(d.getTime())) {
      this.gregorian = '—';
      this.hijri = '—';
      return;
    }
    this.gregorian = new Intl.DateTimeFormat('en-US', {
      year: 'numeric', month: 'short', day: 'numeric',
    }).format(d);
    try {
      this.hijri = new Intl.DateTimeFormat('ar-SA-u-ca-islamic', {
        year: 'numeric', month: 'short', day: 'numeric',
      }).format(d);
    } catch {
      this.hijri = new Intl.DateTimeFormat('ar-SA', {
        year: 'numeric', month: 'short', day: 'numeric',
      }).format(d);
    }
  }

  gregorian = '—';
  hijri = '—';
}
