/**
 * Locale-aware Number Pipe
 *
 * Formats numbers using Intl.NumberFormat based on the current I18nService locale.
 * Uses Western numerals (0-9) for all output — standard in Saudi/UAE banking (SAMA convention).
 * Supports decimal, percent, and compact notation.
 */

import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService, Language } from '../../services/i18n.service';

export type NumberFormatStyle = 'decimal' | 'percent' | 'compact';

const LOCALE_MAP: Record<Language, string> = {
  en: 'en-US',
  ar: 'ar-SA-u-nu-latn',  // Western numerals with Arabic separators
};

@Pipe({
  name: 'localeNumber',
  standalone: true,
  pure: false, // React to locale changes
})
export class LocaleNumberPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(
    value: number | string | null | undefined,
    style: NumberFormatStyle = 'decimal',
    minimumFractionDigits?: number,
    maximumFractionDigits?: number,
  ): string {
    if (value == null || value === '') return '';

    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (Number.isNaN(num)) return typeof value === 'string' ? value : '';

    const locale = LOCALE_MAP[this.i18n.currentLang()] ?? LOCALE_MAP['en'];

    const options: Intl.NumberFormatOptions = {};

    switch (style) {
      case 'percent':
        options.style = 'percent';
        options.minimumFractionDigits = minimumFractionDigits ?? 0;
        options.maximumFractionDigits = maximumFractionDigits ?? 2;
        break;
      case 'compact':
        options.notation = 'compact';
        options.minimumFractionDigits = minimumFractionDigits ?? 0;
        options.maximumFractionDigits = maximumFractionDigits ?? 1;
        break;
      default:
        options.minimumFractionDigits = minimumFractionDigits ?? 0;
        options.maximumFractionDigits = maximumFractionDigits ?? 2;
        break;
    }

    return new Intl.NumberFormat(locale, options).format(num);
  }
}
