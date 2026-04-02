export function normalizeSupportedThemes(themes: string[]): string[] {
  const normalized = themes.map((entry) => {
    const match = entry.match(/\/themes\/([^/]+)\//);
    return match ? match[1] : entry;
  });
  return [...new Set(normalized)];
}
