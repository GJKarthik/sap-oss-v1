import { Injectable, signal, computed, DOCUMENT } from '@angular/core';
import { inject } from '@angular/core';

export type Language = 'en' | 'ar';

interface TranslationMap {
  [key: string]: string;
}

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
    if (typeof fetch !== 'function') {
      this.mfCache.clear();
      this.applyDirection();
      return;
    }

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
      fn = (params: Record<string, unknown>) => this.formatTemplate(raw, params, lang);
      this.mfCache.set(cacheKey, fn);
    }
    return fn;
  }

  private formatTemplate(raw: string, params: Record<string, unknown>, lang: Language): string {
    let result = '';

    for (let cursor = 0; cursor < raw.length;) {
      if (raw[cursor] !== '{') {
        result += raw[cursor];
        cursor += 1;
        continue;
      }

      const closingIndex = this.findMatchingBrace(raw, cursor);
      if (closingIndex === -1) {
        result += raw.slice(cursor);
        break;
      }

      const expression = raw.slice(cursor + 1, closingIndex).trim();
      result += this.evaluateExpression(expression, params, lang);
      cursor = closingIndex + 1;
    }

    return result;
  }

  private evaluateExpression(expression: string, params: Record<string, unknown>, lang: Language): string {
    const pluralMatch = expression.match(/^([^,]+),\s*plural,\s*([\s\S]+)$/);
    if (pluralMatch) {
      return this.evaluatePlural(pluralMatch[1].trim(), pluralMatch[2], params, lang);
    }

    const value = params[expression];
    return value == null ? `{${expression}}` : String(value);
  }

  private evaluatePlural(
    variableName: string,
    optionsSource: string,
    params: Record<string, unknown>,
    lang: Language,
  ): string {
    const count = this.readPluralCount(params[variableName]);
    const options = this.parsePluralOptions(optionsSource);
    const exactKey = `=${count}`;
    const pluralCategory = new Intl.PluralRules(lang).select(count);
    const selected = options.get(exactKey) ?? options.get(pluralCategory) ?? options.get('other') ?? '';

    return this.formatTemplate(selected, params, lang);
  }

  private parsePluralOptions(source: string): Map<string, string> {
    const options = new Map<string, string>();
    let cursor = 0;

    while (cursor < source.length) {
      while (cursor < source.length && /\s/.test(source[cursor])) {
        cursor += 1;
      }

      const selectorStart = cursor;
      while (cursor < source.length && !/\s/.test(source[cursor])) {
        cursor += 1;
      }
      const selector = source.slice(selectorStart, cursor);
      if (!selector) {
        break;
      }

      while (cursor < source.length && /\s/.test(source[cursor])) {
        cursor += 1;
      }

      if (source[cursor] !== '{') {
        break;
      }

      const closingIndex = this.findMatchingBrace(source, cursor);
      if (closingIndex === -1) {
        break;
      }

      options.set(selector, source.slice(cursor + 1, closingIndex));
      cursor = closingIndex + 1;
    }

    return options;
  }

  private findMatchingBrace(source: string, startIndex: number): number {
    let depth = 0;

    for (let cursor = startIndex; cursor < source.length; cursor += 1) {
      if (source[cursor] === '{') {
        depth += 1;
      } else if (source[cursor] === '}') {
        depth -= 1;
        if (depth === 0) {
          return cursor;
        }
      }
    }

    return -1;
  }

  private readPluralCount(value: unknown): number {
    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : 0;
    }

    const numericValue = Number(value);
    return Number.isFinite(numericValue) ? numericValue : 0;
  }

  private applyDirection(): void {
    const html = this.document.documentElement;
    if (html) {
      html.setAttribute('dir', this.dir());
      html.setAttribute('lang', this.currentLang());
    }
  }
}
