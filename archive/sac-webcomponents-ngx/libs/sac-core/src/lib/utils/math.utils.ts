export class SacMathUtils {
  static clamp(value: number, min: number, max: number): number {
    return Math.min(Math.max(value, min), max);
  }

  static round(value: number, decimals: number): number {
    const factor = Math.pow(10, decimals);
    return Math.round(value * factor) / factor;
  }

  static percentage(value: number, total: number): number {
    return total === 0 ? 0 : (value / total) * 100;
  }

  static sum(values: number[]): number {
    return values.reduce((a, b) => a + b, 0);
  }

  static average(values: number[]): number {
    return values.length === 0 ? 0 : SacMathUtils.sum(values) / values.length;
  }
}
