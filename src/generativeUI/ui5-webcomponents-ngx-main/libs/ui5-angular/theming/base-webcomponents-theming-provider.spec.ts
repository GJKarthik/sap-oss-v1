import { normalizeSupportedThemes } from './theme-name.util';

describe('normalizeSupportedThemes', () => {
  it('extracts theme names from generated theme asset paths', () => {
    const normalized = normalizeSupportedThemes([
      'node_modules/@ui5/webcomponents-theming/dist/generated/assets/themes/sap_horizon/parameters-bundle.css.json',
      'node_modules/@ui5/webcomponents-theming/dist/generated/assets/themes/sap_horizon_dark/parameters-bundle.css.json',
    ]);

    expect(normalized).toEqual(['sap_horizon', 'sap_horizon_dark']);
  });

  it('keeps direct theme names and de-duplicates values', () => {
    const normalized = normalizeSupportedThemes([
      'sap_horizon',
      'sap_horizon',
      'sap_fiori_3',
    ]);

    expect(normalized).toEqual(['sap_horizon', 'sap_fiori_3']);
  });
});
