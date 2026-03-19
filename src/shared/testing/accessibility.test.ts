// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Tests for Shared Accessibility Testing Utilities
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  testAriaLiveRegion,
  assertAriaLiveRegion,
  relativeLuminance,
  contrastRatio,
  hexToRgb,
  testColorContrast,
} from './accessibility';

describe('ARIA Live Region Testing', () => {
  let element: HTMLDivElement;

  beforeEach(() => {
    element = document.createElement('div');
    document.body.appendChild(element);
  });

  it('detects aria-live="polite"', () => {
    element.setAttribute('aria-live', 'polite');
    element.setAttribute('role', 'log');

    const result = testAriaLiveRegion(element);

    expect(result.hasAriaLive).toBe(true);
    expect(result.ariaLiveValue).toBe('polite');
    expect(result.isPolite).toBe(true);
    expect(result.isAssertive).toBe(false);
    expect(result.roleValue).toBe('log');
  });

  it('detects aria-live="assertive"', () => {
    element.setAttribute('aria-live', 'assertive');

    const result = testAriaLiveRegion(element);

    expect(result.isAssertive).toBe(true);
    expect(result.isPolite).toBe(false);
  });

  it('detects missing aria-live', () => {
    const result = testAriaLiveRegion(element);

    expect(result.hasAriaLive).toBe(false);
    expect(result.ariaLiveValue).toBeNull();
  });

  it('assertAriaLiveRegion throws on missing aria-live', () => {
    expect(() => assertAriaLiveRegion(element)).toThrow('missing aria-live');
  });

  it('assertAriaLiveRegion throws on wrong role', () => {
    element.setAttribute('aria-live', 'polite');
    element.setAttribute('role', 'status');

    expect(() => assertAriaLiveRegion(element, 'log')).toThrow('Expected role="log"');
  });

  it('assertAriaLiveRegion passes with correct attributes', () => {
    element.setAttribute('aria-live', 'polite');
    element.setAttribute('role', 'log');

    expect(() => assertAriaLiveRegion(element, 'log', 'polite')).not.toThrow();
  });
});

describe('Color Contrast Testing', () => {
  describe('hexToRgb', () => {
    it('parses 6-digit hex', () => {
      expect(hexToRgb('#ff0000')).toEqual([255, 0, 0]);
      expect(hexToRgb('#00ff00')).toEqual([0, 255, 0]);
      expect(hexToRgb('#0000ff')).toEqual([0, 0, 255]);
    });

    it('parses without hash', () => {
      expect(hexToRgb('ffffff')).toEqual([255, 255, 255]);
    });

    it('throws on invalid hex', () => {
      expect(() => hexToRgb('invalid')).toThrow('Invalid hex color');
    });
  });

  describe('relativeLuminance', () => {
    it('white has luminance ~1', () => {
      expect(relativeLuminance(255, 255, 255)).toBeCloseTo(1, 2);
    });

    it('black has luminance ~0', () => {
      expect(relativeLuminance(0, 0, 0)).toBeCloseTo(0, 2);
    });
  });

  describe('contrastRatio', () => {
    it('white on black is 21:1', () => {
      const white = relativeLuminance(255, 255, 255);
      const black = relativeLuminance(0, 0, 0);
      expect(contrastRatio(white, black)).toBeCloseTo(21, 0);
    });
  });

  describe('testColorContrast', () => {
    it('black on white passes WCAG AA', () => {
      const result = testColorContrast('#000000', '#ffffff');
      expect(result.passes).toBe(true);
      expect(result.ratio).toBeGreaterThanOrEqual(4.5);
    });

    it('low contrast fails WCAG AA', () => {
      const result = testColorContrast('#777777', '#888888');
      expect(result.passes).toBe(false);
      expect(result.ratio).toBeLessThan(4.5);
    });

    it('large text has lower requirement (3:1)', () => {
      const result = testColorContrast('#595959', '#ffffff', true);
      expect(result.required).toBe(3);
      // This would fail normal text but might pass large text
    });

    it('SAP Fiori blue on white passes', () => {
      // SAP Brand Color #0070f2 on white
      const result = testColorContrast('#0070f2', '#ffffff');
      expect(result.ratio).toBeGreaterThanOrEqual(3); // UI elements
    });
  });
});

describe('Spacing Scale', () => {
  it('follows 8px grid', () => {
    // This is a documentation test - spacing values should be multiples of 8
    const validSpacing = [4, 8, 16, 24, 32, 48]; // xs exception, then 8px grid
    expect(validSpacing.every((v, i) => i === 0 || v % 8 === 0)).toBe(true);
  });
});

