/**
 * Locale-aware formatting pipes for the Workspace app.
 *
 * Reads the current language from UI5 I18nService and formats using
 * Intl APIs. Uses Western numerals for Arabic locales (SAMA convention).
 */

import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';

const LOCALE_MAP: Record<string, string> = {
  en: 'en-US',
  ar: 'ar-SA-u-nu-latn',
};

function getLocale(i18n: I18nService): string {
  const lang = i18n.currentLanguage() ?? 'en';
  return LOCALE_MAP[lang] ?? LOCALE_MAP['en'];
}

@Pipe({ name: 'localeNumber', standalone: true, pure: false })
export class WorkspaceLocaleNumberPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(value: number | string | null | undefined, minFrac = 0, maxFrac = 2): string {
    if (value == null || value === '') return '';
    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (Number.isNaN(num)) return typeof value === 'string' ? value : '';
    return new Intl.NumberFormat(getLocale(this.i18n), {
      minimumFractionDigits: minFrac,
      maximumFractionDigits: maxFrac,
    }).format(num);
  }
}

@Pipe({ name: 'localeCurrency', standalone: true, pure: false })
export class WorkspaceLocaleCurrencyPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(
    value: number | string | null | undefined,
    currencyCode?: string,
    display: 'symbol' | 'narrowSymbol' | 'code' | 'name' = 'symbol',
  ): string {
    if (value == null || value === '') return '';
    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (Number.isNaN(num)) return typeof value === 'string' ? value : '';

    const lang = this.i18n.currentLanguage() ?? 'en';
    const locale = LOCALE_MAP[lang] ?? LOCALE_MAP['en'];
    const currency = currencyCode ?? (lang === 'ar' ? 'SAR' : 'USD');

    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency,
      currencyDisplay: display,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(num);
  }
}

@Pipe({ name: 'localePercent', standalone: true, pure: false })
export class WorkspaceLocalePercentPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(value: number | string | null | undefined, minFrac = 0, maxFrac = 1): string {
    if (value == null || value === '') return '';
    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (Number.isNaN(num)) return typeof value === 'string' ? value : '';
    return new Intl.NumberFormat(getLocale(this.i18n), {
      style: 'percent',
      minimumFractionDigits: minFrac,
      maximumFractionDigits: maxFrac,
    }).format(num);
  }
}
