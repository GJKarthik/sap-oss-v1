export function normalizeWorkspaceTheme(theme: string | undefined): string {
  if (!theme) return 'sap_horizon';
  if (theme.startsWith('sap_horizon')) return theme;
  if (theme.includes('dark')) return 'sap_horizon_dark';
  return 'sap_horizon';
}
