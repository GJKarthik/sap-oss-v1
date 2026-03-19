/**
 * Adaptive UI Architecture — Rules Module Exports
 */

export * from './default-rules';
export { dataRules } from './data-rules';
export { temporalRules } from './temporal-rules';
export { accessibilityRules } from './accessibility-rules';

import { defaultRules } from './default-rules';
import { dataRules } from './data-rules';
import { temporalRules } from './temporal-rules';
import { accessibilityRules } from './accessibility-rules';
import type { AdaptationRule } from '../types';

/**
 * All rules combined, sorted by priority (highest first).
 * 
 * Priority ranges:
 * - 300+: Accessibility (non-negotiable)
 * - 200-299: Security & Privacy
 * - 100-199: Device & Performance
 * - 50-99: User Preferences & Task Mode
 * - 0-49: Temporal & Contextual
 */
export const allRules: AdaptationRule[] = [
  ...accessibilityRules,
  ...defaultRules,
  ...dataRules,
  ...temporalRules,
].sort((a, b) => b.priority - a.priority);

/**
 * Get rules by category.
 */
export function getRulesByCategory(category: 'accessibility' | 'device' | 'user' | 'task' | 'data' | 'temporal'): AdaptationRule[] {
  const categoryPrefixes: Record<string, string[]> = {
    accessibility: ['a11y-'],
    device: ['device-', 'perf-'],
    user: ['user-'],
    task: ['task-'],
    data: ['data-'],
    temporal: ['temporal-'],
  };
  
  const prefixes = categoryPrefixes[category] || [];
  return allRules.filter(rule => 
    prefixes.some(prefix => rule.id.startsWith(prefix))
  );
}

/**
 * Get only non-overridable rules (accessibility, security).
 */
export function getNonOverridableRules(): AdaptationRule[] {
  return allRules.filter(rule => !rule.userOverridable);
}

