// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Internationalization (i18n) Service
 *
 * Provides translation support for SAC Web Components with:
 * - Built-in English and Arabic translations
 * - RTL direction management
 * - Interpolation via {{param}} syntax
 * - Consumer-extensible translation dictionaries
 */

import { Injectable, OnDestroy } from '@angular/core';
import { BehaviorSubject, Subject } from 'rxjs';

import { SAC_I18N_EN } from '../i18n/en';
import { SAC_I18N_AR } from '../i18n/ar';
import { SAC_I18N_FR } from '../i18n/fr';

export type SacSupportedLocale = 'en' | 'ar' | 'fr';

const RTL_LOCALES: ReadonlySet<string> = new Set(['ar', 'he', 'fa', 'ur']);

const BUILT_IN_TRANSLATIONS: Record<SacSupportedLocale, Record<string, string>> = {
  en: SAC_I18N_EN,
  ar: SAC_I18N_AR,
  fr: SAC_I18N_FR,
};

@Injectable({ providedIn: 'root' })
export class SacI18nService implements OnDestroy {
  private currentLocale: SacSupportedLocale = 'en';
  private translations: Record<string, string> = { ...SAC_I18N_EN };
  private customTranslations = new Map<SacSupportedLocale, Record<string, string>>();

  private readonly localeSubject = new BehaviorSubject<SacSupportedLocale>('en');
  private readonly destroy$ = new Subject<void>();

  readonly locale$ = this.localeSubject.asObservable();

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  /**
   * Get the current locale.
   */
  getLocale(): SacSupportedLocale {
    return this.currentLocale;
  }

  /**
   * Returns true when the current locale is a right-to-left language.
   */
  isRtl(): boolean {
    return RTL_LOCALES.has(this.currentLocale);
  }

  /**
   * Switch the active locale. Updates document dir/lang attributes.
   */
  setLocale(locale: SacSupportedLocale): void {
    this.currentLocale = locale;
    this.rebuildTranslations();
    this.localeSubject.next(locale);

    if (typeof document !== 'undefined') {
      document.documentElement.lang = locale;
      document.documentElement.dir = this.isRtl() ? 'rtl' : 'ltr';
    }
  }

  /**
   * Register additional (or override) translations for a locale.
   * Merges on top of built-in translations.
   */
  registerTranslations(locale: SacSupportedLocale, translations: Record<string, string>): void {
    const existing = this.customTranslations.get(locale) ?? {};
    this.customTranslations.set(locale, { ...existing, ...translations });

    if (locale === this.currentLocale) {
      this.rebuildTranslations();
      this.localeSubject.next(this.currentLocale);
    }
  }

  /**
   * Translate a key with optional interpolation parameters.
   *
   * ```ts
   * i18n.t('chat.risk', { level: 'high' }); // "high risk"
   * ```
   */
  t(key: string, params?: Record<string, string | number>): string {
    let value = this.translations[key];
    if (value === undefined) {
      return key;
    }

    if (params) {
      value = value.replace(/\{\{(\w+)\}\}/g, (match, paramKey: string) => {
        const replacement = params[paramKey];
        return replacement !== undefined ? String(replacement) : match;
      });
    }

    return value;
  }

  /**
   * Shorthand alias for `t()`.
   */
  translate(key: string, params?: Record<string, string | number>): string {
    return this.t(key, params);
  }

  /**
   * Check whether a translation key exists.
   */
  hasKey(key: string): boolean {
    return key in this.translations;
  }

  private rebuildTranslations(): void {
    const builtIn = BUILT_IN_TRANSLATIONS[this.currentLocale] ?? SAC_I18N_EN;
    const custom = this.customTranslations.get(this.currentLocale) ?? {};
    this.translations = { ...builtIn, ...custom };
  }
}
