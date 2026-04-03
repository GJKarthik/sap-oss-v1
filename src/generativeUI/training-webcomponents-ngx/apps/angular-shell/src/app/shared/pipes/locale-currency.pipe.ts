/**
 * Locale-aware Currency Pipe
 *
 * Formats currency values using Intl.NumberFormat based on the current I18nService locale.
 * Uses Western numerals (0-9) for all financial amounts — standard in Saudi/UAE banking.
 * Defaults to SAR when locale is Arabic, USD when English.
 */

import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService, Language } from '../../services/i18n.service';

const LOCALE_MAP: Record<Language, string> = {
  en: 'en-US',
  ar: 'ar-SA-u-nu-latn',
};

const DEFAULT_CURRENCY: Record<Language, string> = {
  en: 'USD',
  ar: 'SAR',
};

@Pipe({
  name: 'localeCurrency',
  standalone: true,
  pure: false,
})
export class LocaleCurrencyPipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(
    value: number | string | null | undefined,
    currencyCode?: string,
    display: 'symbol' | 'narrowSymbol' | 'code' | 'name' = 'symbol',
    minimumFractionDigits?: number,
    maximumFractionDigits?: number,
  ): string {
    if (value == null || value === '') return '';

    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (Number.isNaN(num)) return typeof value === 'string' ? value : '';

    const lang = this.i18n.currentLang();
    const locale = LOCALE_MAP[lang] ?? LOCALE_MAP['en'];
    const currency = currencyCode ?? DEFAULT_CURRENCY[lang] ?? 'USD';

    const options: Intl.NumberFormatOptions = {
      style: 'currency',
      currency,
      currencyDisplay: display,
      minimumFractionDigits: minimumFractionDigits ?? 2,
      maximumFractionDigits: maximumFractionDigits ?? 2,
    };

    return new Intl.NumberFormat(locale, options).format(num);
  }
}
