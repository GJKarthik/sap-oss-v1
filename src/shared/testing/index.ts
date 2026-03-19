// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Shared Testing Utilities
 *
 * @example
 * ```typescript
 * import { testAriaLiveRegion, testColorContrast } from 'src/shared/testing';
 *
 * const result = testAriaLiveRegion(element);
 * expect(result.hasAriaLive).toBe(true);
 * ```
 */

export {
  // ARIA Live Region
  testAriaLiveRegion,
  assertAriaLiveRegion,
  type AriaLiveTestResult,

  // Focus Management
  testFocusManagement,
  type FocusTestResult,

  // Color Contrast
  relativeLuminance,
  contrastRatio,
  hexToRgb,
  testColorContrast,

  // Touch Targets
  testTouchTargets,
} from './accessibility';

