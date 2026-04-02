import { describe, expect, it } from 'vitest';
import { NucleusMathService } from '../libs/sac-builtins/src/lib/services/nucleus-math.service';

describe('NucleusMathService', () => {
  const math = new NucleusMathService();

  // -- Descriptive stats ---------------------------------------------------

  describe('describe', () => {
    it('calculates mean, median, and mode for simple data', () => {
      const stats = math.describe([1, 2, 3, 4, 5]);
      expect(stats.mean).toBe(3);
      expect(stats.median).toBe(3);
      expect(stats.count).toBe(5);
      expect(stats.sum).toBe(15);
      expect(stats.min).toBe(1);
      expect(stats.max).toBe(5);
    });

    it('calculates median for even-length arrays', () => {
      const stats = math.describe([1, 2, 3, 4]);
      expect(stats.median).toBe(2.5);
    });

    it('calculates standard deviation', () => {
      const stats = math.describe([2, 4, 4, 4, 5, 5, 7, 9]);
      expect(stats.stdDev).toBeCloseTo(2.0, 1);
    });

    it('identifies mode', () => {
      const stats = math.describe([1, 2, 2, 3]);
      expect(stats.mode).toContain(2);
    });
  });

  // -- Regression ----------------------------------------------------------

  describe('linearRegression', () => {
    it('finds perfect fit for y = 2x + 1', () => {
      const x = [1, 2, 3, 4, 5];
      const y = [3, 5, 7, 9, 11];
      const result = math.linearRegression(x, y);

      expect(result.slope).toBeCloseTo(2, 6);
      expect(result.intercept).toBeCloseTo(1, 6);
      expect(result.rSquared).toBeCloseTo(1, 6);
    });
  });

  // -- Correlation ---------------------------------------------------------

  describe('correlation', () => {
    it('returns ~1 for perfectly correlated data', () => {
      const result = math.correlation([1, 2, 3, 4, 5], [2, 4, 6, 8, 10]);
      expect(result.coefficient).toBeCloseTo(1, 6);
    });

    it('returns ~-1 for perfectly anti-correlated data', () => {
      const result = math.correlation([1, 2, 3, 4, 5], [10, 8, 6, 4, 2]);
      expect(result.coefficient).toBeCloseTo(-1, 6);
    });
  });

  // -- Financial -----------------------------------------------------------

  describe('npv', () => {
    it('calculates net present value', () => {
      const result = math.npv(0.1, [-1000, 300, 400, 500]);
      expect(result).toBeCloseTo((-1000 + 300 / 1.1 + 400 / 1.21 + 500 / 1.331), 2);
    });
  });

  describe('irr', () => {
    it('finds internal rate of return', () => {
      const rate = math.irr([-1000, 300, 400, 500]);
      // NPV at IRR should be ~0
      const npvAtIrr = math.npv(rate, [-1000, 300, 400, 500]);
      expect(Math.abs(npvAtIrr)).toBeLessThan(0.01);
    });
  });

  // -- Matrix --------------------------------------------------------------

  describe('matrixMultiply', () => {
    it('multiplies 2x2 matrices', () => {
      const result = math.matrixMultiply(
        [[1, 2], [3, 4]],
        [[5, 6], [7, 8]],
      );
      expect(result).toEqual([[19, 22], [43, 50]]);
    });
  });

  describe('matrixTranspose', () => {
    it('transposes a 2x3 matrix', () => {
      const result = math.matrixTranspose([[1, 2, 3], [4, 5, 6]]);
      expect(result).toEqual([[1, 4], [2, 5], [3, 6]]);
    });
  });

  // -- Interpolation -------------------------------------------------------

  describe('linearInterpolate', () => {
    it('interpolates between known points', () => {
      const result = math.linearInterpolate([0, 10], [0, 100], 5);
      expect(result).toBe(50);
    });

    it('returns NaN for out-of-range target', () => {
      const result = math.linearInterpolate([0, 10], [0, 100], 15);
      expect(result).toBeNaN();
    });
  });
});
