export class SacStringUtils {
  static capitalize(s: string): string {
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  static camelToKebab(s: string): string {
    return s.replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase();
  }

  static kebabToCamel(s: string): string {
    return s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
  }

  static truncate(s: string, maxLen: number, suffix = '...'): string {
    return s.length > maxLen ? s.slice(0, maxLen - suffix.length) + suffix : s;
  }

  static isBlank(s: string | null | undefined): boolean {
    return !s || s.trim().length === 0;
  }
}
