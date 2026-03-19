// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Shared Accessibility Testing Utilities
 *
 * Reusable test helpers for WCAG AA compliance across all UI channels:
 * - Data Cleaning Copilot
 * - SAC Web Components
 * - UI5 Web Components NGX
 */

// =============================================================================
// ARIA Live Region Testing
// =============================================================================

export interface AriaLiveTestResult {
  hasAriaLive: boolean;
  ariaLiveValue: string | null;
  hasRole: boolean;
  roleValue: string | null;
  isPolite: boolean;
  isAssertive: boolean;
}

/**
 * Test that an element functions as an ARIA live region.
 */
export function testAriaLiveRegion(element: Element): AriaLiveTestResult {
  const ariaLive = element.getAttribute('aria-live');
  const role = element.getAttribute('role');

  return {
    hasAriaLive: ariaLive !== null,
    ariaLiveValue: ariaLive,
    hasRole: role !== null,
    roleValue: role,
    isPolite: ariaLive === 'polite',
    isAssertive: ariaLive === 'assertive',
  };
}

/**
 * Assert that element is a proper ARIA live region.
 */
export function assertAriaLiveRegion(
  element: Element,
  expectedRole: string = 'log',
  expectedPoliteness: 'polite' | 'assertive' = 'polite'
): void {
  const result = testAriaLiveRegion(element);

  if (!result.hasAriaLive) {
    throw new Error(`Element missing aria-live attribute`);
  }
  if (result.ariaLiveValue !== expectedPoliteness) {
    throw new Error(`Expected aria-live="${expectedPoliteness}", got "${result.ariaLiveValue}"`);
  }
  if (result.roleValue !== expectedRole) {
    throw new Error(`Expected role="${expectedRole}", got "${result.roleValue}"`);
  }
}

// =============================================================================
// Focus Management Testing
// =============================================================================

export interface FocusTestResult {
  hasFocusIndicator: boolean;
  focusVisible: boolean;
  tabIndex: number | null;
  isFocusable: boolean;
}

/**
 * Test focus management for an interactive element.
 */
export function testFocusManagement(element: HTMLElement): FocusTestResult {
  const computedStyle = window.getComputedStyle(element);
  const tabIndex = element.tabIndex;
  const focusableSelector = 'a, button, input, select, textarea, [tabindex]:not([tabindex="-1"])';

  // Check if :focus-visible styles exist
  const hasFocusIndicator =
    computedStyle.outlineStyle !== 'none' ||
    computedStyle.boxShadow !== 'none';

  return {
    hasFocusIndicator,
    focusVisible: element.matches(':focus-visible'),
    tabIndex: tabIndex >= 0 ? tabIndex : null,
    isFocusable: element.matches(focusableSelector) || tabIndex >= 0,
  };
}

// =============================================================================
// Color Contrast Testing (WCAG AA)
// =============================================================================

/**
 * Calculate relative luminance of a color (WCAG 2.1 formula).
 */
export function relativeLuminance(r: number, g: number, b: number): number {
  const sRGB = [r, g, b].map((c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * sRGB[0] + 0.7152 * sRGB[1] + 0.0722 * sRGB[2];
}

/**
 * Calculate contrast ratio between two colors.
 */
export function contrastRatio(l1: number, l2: number): number {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

/**
 * Parse hex color to RGB values.
 */
export function hexToRgb(hex: string): [number, number, number] {
  const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  if (!result) throw new Error(`Invalid hex color: ${hex}`);
  return [parseInt(result[1], 16), parseInt(result[2], 16), parseInt(result[3], 16)];
}

/**
 * Test WCAG AA color contrast (4.5:1 for normal text, 3:1 for large text).
 */
export function testColorContrast(
  foreground: string,
  background: string,
  isLargeText: boolean = false
): { ratio: number; passes: boolean; required: number } {
  const fgRgb = hexToRgb(foreground);
  const bgRgb = hexToRgb(background);
  const fgLum = relativeLuminance(...fgRgb);
  const bgLum = relativeLuminance(...bgRgb);
  const ratio = contrastRatio(fgLum, bgLum);
  const required = isLargeText ? 3 : 4.5;

  return { ratio: Math.round(ratio * 100) / 100, passes: ratio >= required, required };
}

// =============================================================================
// Touch Target Testing
// =============================================================================

const MIN_TOUCH_TARGET = 44; // WCAG 2.5.5 Target Size (Enhanced)

/**
 * Test that interactive elements meet minimum touch target size (44px).
 */
export function testTouchTargets(elements: HTMLElement[]): {
  allPass: boolean;
  results: Array<{ element: HTMLElement; width: number; height: number; passes: boolean }>;
} {
  const results = elements.map((element) => {
    const rect = element.getBoundingClientRect();
    const passes = rect.width >= MIN_TOUCH_TARGET && rect.height >= MIN_TOUCH_TARGET;
    return { element, width: rect.width, height: rect.height, passes };
  });

  return { allPass: results.every((r) => r.passes), results };
}

