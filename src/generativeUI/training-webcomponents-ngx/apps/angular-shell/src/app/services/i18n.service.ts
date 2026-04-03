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
    this.applyDirection();
  }

  toggleLanguage(): void {
    const next: Language = this.currentLang() === 'en' ? 'ar' : 'en';
    this.setLanguage(next);
  }

  setLanguage(lang: Language): void {
    this.currentLang.set(lang);
    localStorage.setItem('app_lang', lang);
    this.applyDirection();
  }

  t(key: string): string {
    const lang = this.currentLang();
    return this.translations[lang]?.[key] ?? this.translations['en']?.[key] ?? key;
  }

  private applyDirection(): void {
    const html = this.document.documentElement;
    if (html) {
      html.setAttribute('dir', this.dir());
      html.setAttribute('lang', this.currentLang());
    }
  }
}

