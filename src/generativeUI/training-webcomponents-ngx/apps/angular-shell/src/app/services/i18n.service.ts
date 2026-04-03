import { Injectable, signal, computed, DOCUMENT } from '@angular/core';
import { inject } from '@angular/core';
import MessageFormat from '@messageformat/core';

export type Language = 'en' | 'ar';

interface TranslationMap {
  [key: string]: string;
}

const LOCALE_MAP: Record<Language, string> = { en: 'en', ar: 'ar' };

@Injectable({ providedIn: 'root' })
export class I18nService {
  private readonly document = inject(DOCUMENT);

  readonly currentLang = signal<Language>(this.loadSavedLang());
  readonly isRtl = computed(() => this.currentLang() === 'ar');
  readonly dir = computed(() => this.isRtl() ? 'rtl' : 'ltr');

  private translations: Record<Language, TranslationMap> = { en: {}, ar: {} };
  private loaded = false;
  private mfCache = new Map<string, (params: Record<string, unknown>) => string>();

  constructor() {
    this.loadTranslations();
  }

  private loadSavedLang(): Language {
    const saved = localStorage.getItem('app_lang');
    return (saved === 'ar' || saved === 'en') ? saved : 'en';
  }

  private async loadTranslations(): Promise<void> {
    try {
      const [enResp, arResp] = await Promise.all([
        fetch('assets/i18n/en.json'),
        fetch('assets/i18n/ar.json'),
      ]);
      this.translations.en = await enResp.json();
      this.translations.ar = await arResp.json();
      this.loaded = true;
    } catch (e) {
      console.warn('Failed to load translations, using keys as fallback', e);
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
    let fn = this.mfCache.get(cacheKey);
    if (!fn) {
      const mf = new MessageFormat(LOCALE_MAP[lang]);
      fn = mf.compile(raw);
      this.mfCache.set(cacheKey, fn);
    }
    return fn;
  }

  private applyDirection(): void {
    const html = this.document.documentElement;
    if (html) {
      html.setAttribute('dir', this.dir());
      html.setAttribute('lang', this.currentLang());
    }
  }
}

