import { normalizeWorkspaceTheme } from './theme-utils';

describe('normalizeWorkspaceTheme', () => {
  it('returns sap_horizon when theme is undefined', () => {
    expect(normalizeWorkspaceTheme(undefined)).toBe('sap_horizon');
  });

  it('returns sap_horizon when theme is empty string', () => {
    expect(normalizeWorkspaceTheme('')).toBe('sap_horizon');
  });

  it('passes through sap_horizon as-is', () => {
    expect(normalizeWorkspaceTheme('sap_horizon')).toBe('sap_horizon');
  });

  it('passes through sap_horizon_dark as-is', () => {
    expect(normalizeWorkspaceTheme('sap_horizon_dark')).toBe('sap_horizon_dark');
  });

  it('passes through sap_horizon_hcb as-is', () => {
    expect(normalizeWorkspaceTheme('sap_horizon_hcb')).toBe('sap_horizon_hcb');
  });

  it('maps a theme containing "dark" to sap_horizon_dark', () => {
    expect(normalizeWorkspaceTheme('some_dark_theme')).toBe('sap_horizon_dark');
  });

  it('falls back to sap_horizon for unknown themes', () => {
    expect(normalizeWorkspaceTheme('sap_fiori_3')).toBe('sap_horizon');
    expect(normalizeWorkspaceTheme('random')).toBe('sap_horizon');
  });
});
