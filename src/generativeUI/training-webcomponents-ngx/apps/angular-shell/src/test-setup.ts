import { setupZoneTestEnv } from 'jest-preset-angular/setup-env/zone';

setupZoneTestEnv();

// Mock fetch for I18nService translation loading in jsdom
if (typeof globalThis.fetch === 'undefined') {
  (globalThis as any).fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({}),
  });
}
