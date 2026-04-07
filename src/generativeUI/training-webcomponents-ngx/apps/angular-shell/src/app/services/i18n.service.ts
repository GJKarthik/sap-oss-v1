import { Injectable, signal, computed, DOCUMENT, isDevMode } from '@angular/core';
import { inject } from '@angular/core';
import MessageFormat from '@messageformat/core';

export type Language = 'en' | 'ar' | 'fr' | 'de' | 'ko' | 'zh' | 'id';

interface TranslationMap {
  [key: string]: string;
}

const LOCALE_MAP: Record<Language, string> = { en: 'en', ar: 'ar', fr: 'fr', de: 'de', ko: 'ko', zh: 'zh', id: 'id' };

@Injectable({ providedIn: 'root' })
export class I18nService {
  private readonly document = inject(DOCUMENT);

  readonly currentLang = signal<Language>(this.loadSavedLang());
  readonly isRtl = computed(() => this.currentLang() === 'ar');
  readonly dir = computed(() => this.isRtl() ? 'rtl' : 'ltr');

  /** Flips to true once translation JSON files have been loaded. */
  readonly translationsReady = signal(false);

  private translations: Record<Language, TranslationMap> = { en: {}, ar: {}, fr: {}, de: {}, ko: {}, zh: {}, id: {} };
  private loaded = false;
  private mfCache = new Map<string, (params: Record<string, unknown>) => string>();

  constructor() {
    // loadTranslations() is called via APP_INITIALIZER in app.config.ts
    // so translations are ready before any component renders.
  }

  private static readonly ALL_LANGS: Language[] = ['en', 'ar', 'fr', 'de', 'ko', 'zh', 'id'];

  private loadSavedLang(): Language {
    const saved = localStorage.getItem('app_lang');
    return I18nService.ALL_LANGS.includes(saved as Language) ? (saved as Language) : 'en';
  }

  async loadTranslations(): Promise<void> {
    if (typeof fetch !== 'function') {
      this.mfCache.clear();
      this.applyDirection();
      return;
    }

    try {
      const responses = await Promise.all(
        I18nService.ALL_LANGS.map(lang => fetch(`assets/i18n/${lang}.json`))
      );
      for (let i = 0; i < I18nService.ALL_LANGS.length; i++) {
        this.translations[I18nService.ALL_LANGS[i]] = await responses[i].json();
      }
      this.loaded = true;
      this.translationsReady.set(true);
    } catch (e) {
      if (isDevMode()) {
        console.warn('Failed to load translations, using keys as fallback', e);
      }
    }
    this.mfCache.clear();
    this.applyDirection();
  }

  toggleLanguage(): void {
    const next: Language = this.currentLang() === 'en' ? 'ar' : 'en';
    this.setLanguage(next);
  }

  setLanguage(lang: Language): void {
    this.currentLang.set(lang);
    localStorage.setItem('app_lang', lang);
    this.mfCache.clear();
    this.applyDirection();
  }

  /**
   * Translate a key, optionally with ICU MessageFormat parameters.
   * Supports Arabic 6-form plurals: zero, one, two, few, many, other.
   * Falls back to English if current language fails, then to the key itself.
   */
  t(key: string, params?: Record<string, unknown>): string {
    const lang = this.currentLang();
    const raw = this.translations[lang]?.[key] ?? this.translations['en']?.[key];
    if (raw == null) return key;

    if (!params) return raw;

    try {
      return this.compileCached(lang, key, raw)(params);
    } catch {
      // Fallback: try English version if current lang ICU parse failed
      if (lang !== 'en') {
        const enRaw = this.translations['en']?.[key];
        if (enRaw) {
          try {
            return this.compileCached('en', key, enRaw)(params);
          } catch {
            // fall through
          }
        }
      }
      // Last resort: return raw string with simple {0}/{1} replacement
      return raw.replace(/\{(\d+)\}/g, (_, idx) => {
        const val = params[idx] ?? params['count'];
        return val != null ? String(val) : _;
      });
    }
  }

  private compileCached(lang: Language, key: string, raw: string): (params: Record<string, unknown>) => string {
    const cacheKey = `${lang}:${key}`;
    const cached = this.mfCache.get(cacheKey);
    if (cached) {
      return cached;
    }

    const mf = new MessageFormat(LOCALE_MAP[lang]);
    const compiled = mf.compile(raw);
    this.mfCache.set(cacheKey, compiled);
    return compiled;
  }

  private applyDirection(): void {
    const html = this.document.documentElement;
    if (html) {
      html.setAttribute('dir', this.dir());
      html.setAttribute('lang', this.currentLang());
    }
  }
}
