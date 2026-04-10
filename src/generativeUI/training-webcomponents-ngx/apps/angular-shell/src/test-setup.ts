import { setupZoneTestEnv } from 'jest-preset-angular/setup-env/zone';
import '@ui5/webcomponents-base/dist/Assets.js';
import '@ui5/webcomponents/dist/Icon.js';
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import './ui5-icons';
import './ui5-locales';

setupZoneTestEnv();

// Mock fetch for I18nService translation loading in jsdom
if (typeof globalThis.fetch === 'undefined') {
  (globalThis as any).fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({}),
  });
}
