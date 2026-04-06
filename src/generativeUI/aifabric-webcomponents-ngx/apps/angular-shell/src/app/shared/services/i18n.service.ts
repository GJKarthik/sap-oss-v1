/**
 * Internationalization (i18n) Service
 * 
 * Provides translation support with lazy loading of translation files,
 * locale detection, and fallback handling.
 */

import { ChangeDetectorRef, Injectable, OnDestroy, Pipe, PipeTransform, inject } from '@angular/core';
import { BehaviorSubject, Observable, Subject, of } from 'rxjs';
import { catchError, shareReplay } from 'rxjs/operators';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export type SupportedLocale = 'en' | 'ar' | 'de' | 'fr' | 'es' | 'ja' | 'zh';

export interface TranslationDictionary {
  [key: string]: string | TranslationDictionary;
}

export interface I18nConfig {
  defaultLocale: SupportedLocale;
  fallbackLocale: SupportedLocale;
  supportedLocales: SupportedLocale[];
  translationsPath: string;
}

@Injectable({
  providedIn: 'root'
})
export class I18nService implements OnDestroy {
  private readonly config: I18nConfig = {
    defaultLocale: 'en',
    fallbackLocale: 'en',
    supportedLocales: ['en', 'ar', 'de', 'fr', 'es', 'ja', 'zh'],
    translationsPath: 'assets/i18n'
  };

  private readonly STORAGE_KEY = 'sap-ai-fabric-locale';
  private readonly localeSubject = new BehaviorSubject<SupportedLocale>(this.config.defaultLocale);
  private readonly destroy$ = new Subject<void>();
  private translationsCache = new Map<SupportedLocale, Observable<TranslationDictionary>>();
  private currentTranslations: TranslationDictionary = {};

  readonly locale$ = this.localeSubject.asObservable();
  private readonly http = inject(HttpClient);

  constructor() {
    this.initialize();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  /**
   * Get the current locale
   */
  getCurrentLocale(): SupportedLocale {
    return this.localeSubject.value;
  }

  /**
   * Set the locale and load translations
   */
  async setLocale(locale: SupportedLocale): Promise<void> {
    if (!this.config.supportedLocales.includes(locale)) {
      if (!environment.production) {
        console.warn(`Locale "${locale}" is not supported. Falling back to "${this.config.fallbackLocale}"`);
      }
      locale = this.config.fallbackLocale;
    }

    // Save preference
    localStorage.setItem(this.STORAGE_KEY, locale);

    // Load translations
    try {
      await this.loadTranslations(locale);
      this.localeSubject.next(locale);
      
      // Update document language and direction
      document.documentElement.lang = locale;
      document.documentElement.dir = locale === 'ar' ? 'rtl' : 'ltr';
    } catch (error) {
      if (!environment.production) {
        console.error(`Failed to load translations for "${locale}":`, error);
      }
      
      // Fallback to default if not already
      if (locale !== this.config.fallbackLocale) {
        await this.setLocale(this.config.fallbackLocale);
      }
    }
  }

  /**
   * Translate a key with optional interpolation
   */
  translate(key: string, params?: Record<string, string | number>): string {
    const value = this.getNestedValue(this.currentTranslations, key);
    
    if (typeof value !== 'string') {
      if (!environment.production) {
        console.warn(`Translation key "${key}" not found`);
      }
      return key;
    }

    // Handle parameter interpolation {{param}}
    if (params) {
      return value.replace(/\{\{(\w+)\}\}/g, (match, paramKey) => {
        return params[paramKey]?.toString() ?? match;
      });
    }

    return value;
  }

  /**
   * Shorthand for translate
   */
  t(key: string, params?: Record<string, string | number>): string {
    return this.translate(key, params);
  }

  /**
   * Check if a translation key exists
   */
  hasTranslation(key: string): boolean {
    return typeof this.getNestedValue(this.currentTranslations, key) === 'string';
  }

  /**
   * Get all supported locales with their display names
   */
  getSupportedLocales(): Array<{ code: SupportedLocale; name: string; nativeName: string }> {
    const localeNames: Record<SupportedLocale, { name: string; nativeName: string }> = {
      en: { name: 'English', nativeName: 'English' },
      ar: { name: 'Arabic', nativeName: 'العربية' },
      de: { name: 'German', nativeName: 'Deutsch' },
      fr: { name: 'French', nativeName: 'Français' },
      es: { name: 'Spanish', nativeName: 'Español' },
      ja: { name: 'Japanese', nativeName: '日本語' },
      zh: { name: 'Chinese', nativeName: '中文' }
    };

    return this.config.supportedLocales.map(code => ({
      code,
      ...localeNames[code]
    }));
  }

  private initialize(): void {
    // Detect locale from storage or browser
    const savedLocale = localStorage.getItem(this.STORAGE_KEY) as SupportedLocale | null;
    const browserLocale = this.detectBrowserLocale();
    const locale = savedLocale || browserLocale || this.config.defaultLocale;

    // Load initial translations
    void this.setLocale(locale);
  }

  private detectBrowserLocale(): SupportedLocale | null {
    if (typeof navigator === 'undefined') {
      return null;
    }

    const browserLang = navigator.language?.split('-')[0] as SupportedLocale;
    
    if (this.config.supportedLocales.includes(browserLang)) {
      return browserLang;
    }

    return null;
  }

  private loadTranslations(locale: SupportedLocale): Promise<void> {
    // Check cache first
    if (!this.translationsCache.has(locale)) {
      const url = `${this.config.translationsPath}/${locale}.json`;
      
      const translation$ = this.http.get<TranslationDictionary>(url).pipe(
        catchError(error => {
          if (!environment.production) {
            console.error(`Failed to load translations from ${url}:`, error);
          }
          return of({});
        }),
        shareReplay(1)
      );

      this.translationsCache.set(locale, translation$);
    }

    return new Promise((resolve, reject) => {
      this.translationsCache.get(locale)!.subscribe({
        next: translations => {
          this.currentTranslations = translations;
          resolve();
        },
        error: reject
      });
    });
  }

  private getNestedValue(obj: TranslationDictionary, key: string): string | TranslationDictionary | undefined {
    const keys = key.split('.');
    let current: string | TranslationDictionary | undefined = obj;

    for (const k of keys) {
      if (current === undefined || typeof current === 'string') {
        return undefined;
      }
      current = current[k];
    }

    return current;
  }
}

/**
 * Translation Pipe
 * 
 * Use in templates: {{ 'key.path' | translate }}
 * With params: {{ 'key.path' | translate:{ name: 'value' } }}
 */
import { Subscription } from 'rxjs';

@Pipe({
  name: 'translate',
  standalone: true,
  pure: false // Impure to react to locale changes
})
export class TranslatePipe implements PipeTransform, OnDestroy {
  private value = '';
  private lastKey = '';
  private lastParams: Record<string, string | number> | undefined;
  private subscription: Subscription | null = null;
  private readonly i18n = inject(I18nService);
  private readonly cdr = inject(ChangeDetectorRef);

  constructor() {
    // Subscribe to locale changes
    this.subscription = this.i18n.locale$.subscribe(() => {
      this.updateValue();
    });
  }

  ngOnDestroy(): void {
    if (this.subscription) {
      this.subscription.unsubscribe();
    }
  }

  transform(key: string, params?: Record<string, string | number>): string {
    if (key !== this.lastKey || params !== this.lastParams) {
      this.lastKey = key;
      this.lastParams = params;
      this.updateValue();
    }
    return this.value;
  }

  private updateValue(): void {
    if (this.lastKey) {
      this.value = this.i18n.translate(this.lastKey, this.lastParams);
      this.cdr.markForCheck();
    }
  }
}