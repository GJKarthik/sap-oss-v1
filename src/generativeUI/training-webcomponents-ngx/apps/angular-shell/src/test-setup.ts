import { setupZoneTestEnv } from 'jest-preset-angular/setup-env/zone';

setupZoneTestEnv();

// UI5 asset registration is not required in JSDOM and triggers theming lookups
// against document internals that do not exist in unit tests.

// Mock fetch for I18nService translation loading in jsdom
if (typeof globalThis.fetch === 'undefined') {
  (globalThis as any).fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({}),
  });
}
