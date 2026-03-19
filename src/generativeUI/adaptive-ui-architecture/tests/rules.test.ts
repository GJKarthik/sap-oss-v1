/**
 * Adaptive UI Architecture — Adaptation Rules Tests
 */

import { describe, it, expect } from 'vitest';
import { 
  allRules, 
  accessibilityRules, 
  getRulesByCategory,
  getNonOverridableRules 
} from '../core/adaptation/rules';
import type { AdaptiveContext } from '../core/context/types';

function createMockContext(overrides: Partial<AdaptiveContext> = {}): AdaptiveContext {
  return {
    user: {
      userId: 'user-123',
      role: { id: 'user', name: 'User', permissionLevel: 'editor', expertiseLevel: 'intermediate' },
      organization: 'Test',
      locale: 'en-US',
      timezone: 'UTC',
    },
    task: {
      mode: 'explore',
      complexity: 'moderate',
      urgency: 'normal',
      inWorkflow: false,
    },
    temporal: {
      timeOfDay: 'afternoon',
      dayOfWeek: 3,
      businessPeriod: 'mid-day',
      sessionDurationMinutes: 15,
    },
    device: {
      type: 'desktop',
      screenWidth: 1920,
      screenHeight: 1080,
      pixelRatio: 1,
      hasTouch: false,
      pointerPrecision: 'fine',
      connectionType: 'wifi',
      prefersReducedMotion: false,
      prefersColorScheme: 'light',
      prefersContrast: 'no-preference',
    },
    data: {
      rowCount: 100,
      columnCount: 10,
      dataAge: 'live',
      dataQuality: 'verified',
      sensitivityLevel: 'internal',
      hasFilters: true,
      hasSorting: true,
      updateFrequency: 'periodic',
    },
    generatedAt: new Date(),
    confidence: 0.8,
    ...overrides,
  };
}

describe('Adaptation Rules', () => {
  describe('rule organization', () => {
    it('should have rules sorted by priority', () => {
      for (let i = 1; i < allRules.length; i++) {
        expect(allRules[i - 1].priority).toBeGreaterThanOrEqual(allRules[i].priority);
      }
    });

    it('should have accessibility rules at highest priority', () => {
      const a11yRules = accessibilityRules;
      const minA11yPriority = Math.min(...a11yRules.map(r => r.priority));
      
      // All a11y rules should be >= 200
      expect(minA11yPriority).toBeGreaterThanOrEqual(200);
    });
  });

  describe('reduced motion rule', () => {
    it('should trigger when prefers-reduced-motion is true', () => {
      const ctx = createMockContext({
        device: {
          ...createMockContext().device,
          prefersReducedMotion: true,
        },
      });
      
      const rule = accessibilityRules.find(r => r.id === 'a11y-reduced-motion');
      expect(rule).toBeDefined();
      expect(rule!.condition(ctx, null)).toBe(true);
    });

    it('should set animation scale to 0', () => {
      const ctx = createMockContext({
        device: {
          ...createMockContext().device,
          prefersReducedMotion: true,
        },
      });
      
      const rule = accessibilityRules.find(r => r.id === 'a11y-reduced-motion')!;
      const result = rule.apply({}, ctx, null);
      
      expect(result.interaction?.animationScale).toBe(0);
    });

    it('should not be user-overridable', () => {
      const rule = accessibilityRules.find(r => r.id === 'a11y-reduced-motion');
      expect(rule!.userOverridable).toBe(false);
    });
  });

  describe('touch device rule', () => {
    it('should trigger for touch devices with coarse pointer', () => {
      const ctx = createMockContext({
        device: {
          ...createMockContext().device,
          hasTouch: true,
          pointerPrecision: 'coarse',
        },
      });
      
      const rule = accessibilityRules.find(r => r.id === 'a11y-touch-device');
      expect(rule!.condition(ctx, null)).toBe(true);
    });

    it('should increase touch target scale', () => {
      const ctx = createMockContext({
        device: {
          ...createMockContext().device,
          hasTouch: true,
          pointerPrecision: 'coarse',
        },
      });
      
      const rule = accessibilityRules.find(r => r.id === 'a11y-touch-device')!;
      const result = rule.apply({}, ctx, null);
      
      expect(result.interaction?.touchTargetScale).toBeGreaterThanOrEqual(1.25);
    });
  });

  describe('category helpers', () => {
    it('should get accessibility rules by category', () => {
      const rules = getRulesByCategory('accessibility');
      expect(rules.length).toBeGreaterThan(0);
      expect(rules.every(r => r.id.startsWith('a11y-'))).toBe(true);
    });

    it('should get non-overridable rules', () => {
      const rules = getNonOverridableRules();
      expect(rules.length).toBeGreaterThan(0);
      expect(rules.every(r => r.userOverridable === false)).toBe(true);
    });
  });
});

