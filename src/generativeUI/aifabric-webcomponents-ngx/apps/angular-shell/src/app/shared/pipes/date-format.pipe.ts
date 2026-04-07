/**
 * Date Format Pipe
 *
 * A locale-aware date formatting pipe using Intl.DateTimeFormat.
 * Reads the current locale from I18nService instead of hardcoded en-US.
 * Uses Western numerals for Arabic locales (SAMA convention).
 */

import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService, SupportedLocale } from '../services/i18n.service';

export type DateFormatStyle = 'short' | 'medium' | 'long' | 'full' | 'relative' | 'datetime' | 'date' | 'time';

const LOCALE_MAP: Partial<Record<SupportedLocale, string>> & { default: string } = {
  en: 'en-US',
  ar: 'ar-SA-u-nu-latn',
  de: 'de-DE',
  fr: 'fr-FR',
  ko: 'ko-KR',
  zh: 'zh-CN',
  id: 'id-ID',
  default: 'en-US',
};

const FORMAT_OPTIONS: Record<string, Intl.DateTimeFormatOptions> = {
  short: { year: 'numeric', month: 'numeric', day: 'numeric' },
  medium: { year: 'numeric', month: 'short', day: 'numeric' },
  long: { year: 'numeric', month: 'long', day: 'numeric' },
  full: { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' },
  datetime: { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true },
  date: { year: 'numeric', month: 'short', day: 'numeric' },
  time: { hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true },
};

@Pipe({
  name: 'dateFormat',
  standalone: true,
  pure: false,
})
export class DateFormatPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(value: string | number | Date | null | undefined, style: DateFormatStyle = 'datetime'): string {
    if (!value) {
      return 'n/a';
    }

    const date = value instanceof Date ? value : new Date(value);

    if (Number.isNaN(date.getTime())) {
      return typeof value === 'string' ? value : 'Invalid date';
    }

    const locale = this.getLocale();

    if (style === 'relative') {
      return this.getRelativeTime(date, locale);
    }

    const options = FORMAT_OPTIONS[style] || FORMAT_OPTIONS['datetime'];
    return new Intl.DateTimeFormat(locale, options).format(date);
  }

  private getLocale(): string {
    const currentLocale = this.i18n.getCurrentLocale();
    return LOCALE_MAP[currentLocale] ?? LOCALE_MAP.default;
  }

  private getRelativeTime(date: Date, locale: string): string {
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffSeconds = Math.floor(diffMs / 1000);
    const diffMinutes = Math.floor(diffSeconds / 60);
    const diffHours = Math.floor(diffMinutes / 60);
    const diffDays = Math.floor(diffHours / 24);
    const diffWeeks = Math.floor(diffDays / 7);
    const diffMonths = Math.floor(diffDays / 30);
    const diffYears = Math.floor(diffDays / 365);

    if (diffMs < 0) {
      return new Intl.DateTimeFormat(locale, FORMAT_OPTIONS['datetime']).format(date);
    }

    if (diffSeconds < 60) return 'Just now';
    if (diffMinutes < 60) return diffMinutes === 1 ? '1 minute ago' : `${diffMinutes} minutes ago`;
    if (diffHours < 24) return diffHours === 1 ? '1 hour ago' : `${diffHours} hours ago`;
    if (diffDays < 7) return diffDays === 1 ? 'Yesterday' : `${diffDays} days ago`;
    if (diffWeeks < 4) return diffWeeks === 1 ? '1 week ago' : `${diffWeeks} weeks ago`;
    if (diffMonths < 12) return diffMonths === 1 ? '1 month ago' : `${diffMonths} months ago`;
    return diffYears === 1 ? '1 year ago' : `${diffYears} years ago`;
  }
}