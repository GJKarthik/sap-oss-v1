export class SacDateUtils {
  static toISODate(date: Date): string {
    return date.toISOString().split('T')[0];
  }

  static fromISODate(iso: string): Date {
    return new Date(iso);
  }

  static addDays(date: Date, days: number): Date {
    const result = new Date(date);
    result.setDate(result.getDate() + days);
    return result;
  }

  static diffDays(a: Date, b: Date): number {
    const ms = Math.abs(a.getTime() - b.getTime());
    return Math.floor(ms / (1000 * 60 * 60 * 24));
  }

  static formatDate(date: Date, locale = 'en-US'): string {
    return date.toLocaleDateString(locale);
  }
}
