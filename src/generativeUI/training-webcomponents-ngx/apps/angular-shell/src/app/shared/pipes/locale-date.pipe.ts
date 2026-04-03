/**
 * Locale-aware Date Pipe
 *
 * Formats dates using Intl.DateTimeFormat based on the current I18nService locale.
 * Supports short/medium/long/relative formats, Gregorian by default with Hijri option.
 * Relative time uses I18nService translation keys for proper Arabic pluralization.
 */

import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService, Language } from '../../services/i18n.service';

export type LocaleDateFormatStyle = 'short' | 'medium' | 'long' | 'full' | 'relative' | 'datetime' | 'date' | 'time';

const LOCALE_MAP: Record<Language, string> = {
  en: 'en-US',
  ar: 'ar-SA-u-nu-latn',
};

@Pipe({
  name: 'localeDate',
  standalone: true,
  pure: false,
})
export class LocaleDatePipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(
    value: string | number | Date | null | undefined,
    style: LocaleDateFormatStyle = 'datetime',
    calendar?: 'gregorian' | 'hijri',
  ): string {
    if (!value) return '';

    const date = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(date.getTime())) {
      return typeof value === 'string' ? value : '';
    }

    if (style === 'relative') {
      return this.getRelativeTime(date);
    }

    const lang = this.i18n.currentLang();
    let locale = LOCALE_MAP[lang] ?? LOCALE_MAP['en'];
    if (calendar === 'hijri' && lang === 'ar') {
      locale = 'ar-SA-u-ca-islamic-nu-latn';
    }

    const options = this.getOptions(style);
    return new Intl.DateTimeFormat(locale, options).format(date);
  }

  private getOptions(style: LocaleDateFormatStyle): Intl.DateTimeFormatOptions {
    switch (style) {
      case 'short':
        return { year: 'numeric', month: 'numeric', day: 'numeric' };
      case 'medium':
        return { year: 'numeric', month: 'short', day: 'numeric' };
      case 'long':
        return { year: 'numeric', month: 'long', day: 'numeric' };
      case 'full':
        return { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
      case 'date':
        return { year: 'numeric', month: 'short', day: 'numeric' };
      case 'time':
        return { hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true };
      case 'datetime':
      default:
        return { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true };
    }
  }

  private getRelativeTime(date: Date): string {
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffSeconds = Math.floor(Math.abs(diffMs) / 1000);
    const diffMinutes = Math.floor(diffSeconds / 60);
    const diffHours = Math.floor(diffMinutes / 60);
    const diffDays = Math.floor(diffHours / 24);
    const diffWeeks = Math.floor(diffDays / 7);
    const diffMonths = Math.floor(diffDays / 30);
    const diffYears = Math.floor(diffDays / 365);

    // Future dates — just format normally
    if (diffMs < 0) {
      const lang = this.i18n.currentLang();
      const locale = LOCALE_MAP[lang] ?? LOCALE_MAP['en'];
      return new Intl.DateTimeFormat(locale, this.getOptions('datetime')).format(date);
    }

    if (diffSeconds < 60) return this.i18n.t('relative.justNow');
    if (diffMinutes < 60) return this.i18n.t('relative.minutesAgo', { count: diffMinutes });
    if (diffHours < 24) return this.i18n.t('relative.hoursAgo', { count: diffHours });
    if (diffDays === 1) return this.i18n.t('relative.yesterday');
    if (diffDays < 7) return this.i18n.t('relative.daysAgo', { count: diffDays });
    if (diffWeeks < 4) return this.i18n.t('relative.weeksAgo', { count: diffWeeks });
    if (diffMonths < 12) return this.i18n.t('relative.monthsAgo', { count: diffMonths });
    return this.i18n.t('relative.yearsAgo', { count: diffYears });
  }
}
