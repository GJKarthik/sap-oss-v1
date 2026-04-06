import { TestBed } from '@angular/core/testing';
import { I18nService } from './i18n.service';

interface I18nServiceTestAccess {
  translations: Record<'en' | 'ar', Record<string, string>>;
  loaded: boolean;
  mfCache: Map<string, (params: Record<string, unknown>) => string>;
}

describe('I18nService – ICU MessageFormat', () => {
  let service: I18nService;

  const enTranslations: Record<string, string> = {
    'chat.lastTokens': "Last: {count, plural, =0 {0 tokens} one {1 token} other {{count} tokens}}",
    'pipeline.lines': "{count, plural, =0 {no lines} one {1 line} other {{count} lines}}",
    'dashboard.gpuMemTotal': "of {total} GB total",
    'modelOpt.vramRequired': "{required} GB required / {available} GB available",
    'simple.key': "Hello World",
  };
  const arTranslations: Record<string, string> = {
    'chat.lastTokens': "الأخير: {count, plural, =0 {لا رموز} one {رمز واحد} two {رمزان} few {{count} رموز} many {{count} رمزًا} other {{count} رمز}}",
    'pipeline.lines': "{count, plural, =0 {لا أسطر} one {سطر واحد} two {سطران} few {{count} أسطر} many {{count} سطرًا} other {{count} سطر}}",
    'dashboard.gpuMemTotal': "من {total} جيجابايت إجمالي",
    'simple.key': "مرحبا بالعالم",
  };

  beforeEach(() => {
    localStorage.clear();
    // Mock fetch to prevent real HTTP calls
    const fetchMock = jest.fn((input: RequestInfo | URL) => {
      const url = String(input);
      const body = url.includes('ar.json') ? arTranslations : enTranslations;
      return Promise.resolve({ json: () => Promise.resolve(body) } as Response);
    }) as typeof fetch;
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      value: fetchMock,
    });

    TestBed.configureTestingModule({});
    service = TestBed.inject(I18nService);
    // Directly inject translations to avoid async loading issues
    const serviceState = service as unknown as I18nServiceTestAccess;
    serviceState.translations = { en: enTranslations, ar: arTranslations };
    serviceState.loaded = true;
    serviceState.mfCache.clear();
  });

  afterEach(() => {
    jest.restoreAllMocks();
    localStorage.clear();
  });

  // ─── English plurals ───────────────────────────────────────────────────────

  describe('English plurals', () => {
    beforeEach(() => {
      service.setLanguage('en');
    });

    it('chat.lastTokens with count=0', () => {
      expect(service.t('chat.lastTokens', { count: 0 })).toBe('Last: 0 tokens');
    });
    it('chat.lastTokens with count=1', () => {
      expect(service.t('chat.lastTokens', { count: 1 })).toBe('Last: 1 token');
    });
    it('chat.lastTokens with count=42', () => {
      expect(service.t('chat.lastTokens', { count: 42 })).toBe('Last: 42 tokens');
    });
    it('pipeline.lines with count=0', () => {
      expect(service.t('pipeline.lines', { count: 0 })).toBe('no lines');
    });
    it('pipeline.lines with count=1', () => {
      expect(service.t('pipeline.lines', { count: 1 })).toBe('1 line');
    });
    it('pipeline.lines with count=100', () => {
      expect(service.t('pipeline.lines', { count: 100 })).toBe('100 lines');
    });
    it('named params (dashboard.gpuMemTotal)', () => {
      expect(service.t('dashboard.gpuMemTotal', { total: 24 })).toBe('of 24 GB total');
    });
    it('simple key without params returns raw string', () => {
      expect(service.t('simple.key')).toBe('Hello World');
    });
    it('missing key returns key itself', () => {
      expect(service.t('nonexistent.key')).toBe('nonexistent.key');
    });
  });

  // ─── Arabic 6-form plurals ─────────────────────────────────────────────────

  describe('Arabic 6-form plurals', () => {
    beforeEach(() => {
      service.setLanguage('ar');
    });

    // chat.lastTokens – all 6 Arabic plural forms
    it('chat.lastTokens: zero (count=0)', () => {
      expect(service.t('chat.lastTokens', { count: 0 })).toBe('الأخير: لا رموز');
    });
    it('chat.lastTokens: one (count=1)', () => {
      expect(service.t('chat.lastTokens', { count: 1 })).toBe('الأخير: رمز واحد');
    });
    it('chat.lastTokens: two (count=2)', () => {
      expect(service.t('chat.lastTokens', { count: 2 })).toBe('الأخير: رمزان');
    });
    it('chat.lastTokens: few (count=5)', () => {
      expect(service.t('chat.lastTokens', { count: 5 })).toBe('الأخير: 5 رموز');
    });
    it('chat.lastTokens: many (count=11)', () => {
      expect(service.t('chat.lastTokens', { count: 11 })).toBe('الأخير: 11 رمزًا');
    });
    it('chat.lastTokens: other (count=100)', () => {
      expect(service.t('chat.lastTokens', { count: 100 })).toBe('الأخير: 100 رمز');
    });

    // pipeline.lines – all 6 Arabic plural forms
    it('pipeline.lines: zero (count=0)', () => {
      expect(service.t('pipeline.lines', { count: 0 })).toBe('لا أسطر');
    });
    it('pipeline.lines: one (count=1)', () => {
      expect(service.t('pipeline.lines', { count: 1 })).toBe('سطر واحد');
    });
    it('pipeline.lines: two (count=2)', () => {
      expect(service.t('pipeline.lines', { count: 2 })).toBe('سطران');
    });
    it('pipeline.lines: few (count=3)', () => {
      expect(service.t('pipeline.lines', { count: 3 })).toBe('3 أسطر');
    });
    it('pipeline.lines: many (count=50)', () => {
      expect(service.t('pipeline.lines', { count: 50 })).toBe('50 سطرًا');
    });
    it('pipeline.lines: other (count=101)', () => {
      expect(service.t('pipeline.lines', { count: 101 })).toBe('101 سطر');
    });

    // Fallback to English if Arabic key is missing
    it('falls back to English for missing Arabic key', () => {
      expect(service.t('modelOpt.vramRequired', { required: '4.5', available: 16 }))
        .toBe('4.5 GB required / 16 GB available');
    });
  });
});
