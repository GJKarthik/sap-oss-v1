/**
 * NucleusMath Service
 *
 * Angular wrapper for statistical, mathematical, financial, and matrix operations.
 * Wraps NucleusMath from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';

import type { RegressionResult, CorrelationResult, DescriptiveStats } from '../types/builtins.types';

@Injectable()
export class NucleusMathService {
  // -- Descriptive stats -----------------------------------------------------

  describe(values: number[]): DescriptiveStats {
    const sorted = [...values].sort((a, b) => a - b);
    const n = sorted.length;
    const sum = sorted.reduce((s, v) => s + v, 0);
    const mean = sum / n;
    const variance = sorted.reduce((s, v) => s + (v - mean) ** 2, 0) / n;
    const stdDev = Math.sqrt(variance);
    const median = n % 2 === 0
      ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2
      : sorted[Math.floor(n / 2)];

    // Mode
    const freq = new Map<number, number>();
    let maxFreq = 0;
    for (const v of sorted) {
      const f = (freq.get(v) || 0) + 1;
      freq.set(v, f);
      if (f > maxFreq) maxFreq = f;
    }
    const mode = [...freq.entries()].filter(([, f]) => f === maxFreq).map(([v]) => v);

    // Skewness & Kurtosis
    const m3 = sorted.reduce((s, v) => s + ((v - mean) / stdDev) ** 3, 0) / n;
    const m4 = sorted.reduce((s, v) => s + ((v - mean) / stdDev) ** 4, 0) / n - 3;

    return {
      mean, median, mode, stdDev, variance,
      min: sorted[0], max: sorted[n - 1],
      count: n, sum,
      skewness: m3, kurtosis: m4,
    };
  }

  // -- Regression ------------------------------------------------------------

  linearRegression(x: number[], y: number[]): RegressionResult {
    const n = x.length;
    const sumX = x.reduce((s, v) => s + v, 0);
    const sumY = y.reduce((s, v) => s + v, 0);
    const sumXY = x.reduce((s, v, i) => s + v * y[i], 0);
    const sumX2 = x.reduce((s, v) => s + v * v, 0);
    const sumY2 = y.reduce((s, v) => s + v * v, 0);

    const slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
    const intercept = (sumY - slope * sumX) / n;

    const ssRes = y.reduce((s, v, i) => s + (v - (slope * x[i] + intercept)) ** 2, 0);
    const ssTot = y.reduce((s, v) => s + (v - sumY / n) ** 2, 0);
    const rSquared = 1 - ssRes / ssTot;
    const standardError = Math.sqrt(ssRes / (n - 2));

    return { slope, intercept, rSquared, standardError };
  }

  // -- Correlation -----------------------------------------------------------

  correlation(x: number[], y: number[]): CorrelationResult {
    const n = x.length;
    const mx = x.reduce((s, v) => s + v, 0) / n;
    const my = y.reduce((s, v) => s + v, 0) / n;
    let num = 0, dx2 = 0, dy2 = 0;
    for (let i = 0; i < n; i++) {
      const dx = x[i] - mx;
      const dy = y[i] - my;
      num += dx * dy;
      dx2 += dx * dx;
      dy2 += dy * dy;
    }
    const coefficient = num / Math.sqrt(dx2 * dy2);
    // Approximate p-value via t-distribution
    const t = coefficient * Math.sqrt((n - 2) / (1 - coefficient * coefficient));
    const pValue = Math.exp(-0.5 * t * t); // rough approximation
    return { coefficient, pValue };
  }

  // -- Financial -------------------------------------------------------------

  npv(rate: number, cashFlows: number[]): number {
    return cashFlows.reduce((s, cf, i) => s + cf / Math.pow(1 + rate, i), 0);
  }

  irr(cashFlows: number[], guess = 0.1): number {
    let rate = guess;
    for (let iter = 0; iter < 100; iter++) {
      const npv = this.npv(rate, cashFlows);
      const dNpv = cashFlows.reduce((s, cf, i) => s - i * cf / Math.pow(1 + rate, i + 1), 0);
      const newRate = rate - npv / dNpv;
      if (Math.abs(newRate - rate) < 1e-10) return newRate;
      rate = newRate;
    }
    return rate;
  }

  // -- Matrix ----------------------------------------------------------------

  matrixMultiply(a: number[][], b: number[][]): number[][] {
    const rows = a.length;
    const cols = b[0].length;
    const k = b.length;
    const result: number[][] = Array.from({ length: rows }, () => new Array(cols).fill(0));
    for (let i = 0; i < rows; i++) {
      for (let j = 0; j < cols; j++) {
        for (let m = 0; m < k; m++) {
          result[i][j] += a[i][m] * b[m][j];
        }
      }
    }
    return result;
  }

  matrixTranspose(m: number[][]): number[][] {
    const rows = m.length;
    const cols = m[0].length;
    return Array.from({ length: cols }, (_, j) =>
      Array.from({ length: rows }, (_, i) => m[i][j]),
    );
  }

  // -- Interpolation ---------------------------------------------------------

  linearInterpolate(x: number[], y: number[], target: number): number {
    for (let i = 0; i < x.length - 1; i++) {
      if (target >= x[i] && target <= x[i + 1]) {
        const t = (target - x[i]) / (x[i + 1] - x[i]);
        return y[i] + t * (y[i + 1] - y[i]);
      }
    }
    return NaN;
  }
}
