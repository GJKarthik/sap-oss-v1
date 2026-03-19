/**
 * Adaptive UI Architecture — Adaptation Coordinator Tests
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';

// Mock DOM
const mockSetProperty = vi.fn();
Object.defineProperty(global, 'document', {
  value: {
    documentElement: {
      style: {
        setProperty: mockSetProperty,
      },
    },
  },
  writable: true,
});

// Mock localStorage
const localStorageMock = (() => {
  let store: Record<string, string> = {};
  return {
    getItem: (key: string) => store[key] || null,
    setItem: (key: string, value: string) => { store[key] = value; },
    removeItem: (key: string) => { delete store[key]; },
    clear: () => { store = {}; },
  };
})();
Object.defineProperty(global, 'localStorage', { value: localStorageMock });

// Mock window
Object.defineProperty(global, 'window', {
  value: {
    innerWidth: 1920,
    innerHeight: 1080,
    devicePixelRatio: 1,
    matchMedia: vi.fn().mockImplementation(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
    addEventListener: vi.fn(),
  },
  writable: true,
});

Object.defineProperty(global, 'navigator', {
  value: { language: 'en-US', maxTouchPoints: 0 },
  writable: true,
});

// Import after mocking
import { AdaptationCoordinator } from '../core/adaptation/coordinator';

describe('AdaptationCoordinator', () => {
  let coordinator: AdaptationCoordinator;

  beforeEach(() => {
    localStorageMock.clear();
    mockSetProperty.mockClear();
    coordinator = new AdaptationCoordinator({ autoStart: false });
  });

  afterEach(() => {
    coordinator.stop();
  });

  describe('lifecycle', () => {
    it('should start and stop correctly', () => {
      expect(coordinator.isActive()).toBe(false);
      
      coordinator.start();
      expect(coordinator.isActive()).toBe(true);
      
      coordinator.stop();
      expect(coordinator.isActive()).toBe(false);
    });

    it('should not double-start', () => {
      coordinator.start();
      coordinator.start();
      expect(coordinator.isActive()).toBe(true);
    });
  });

  describe('subscription', () => {
    it('should notify listeners of decisions', () => {
      const listener = vi.fn();
      coordinator.start();
      
      coordinator.subscribe(listener);
      coordinator.forceAdapt();
      
      expect(listener).toHaveBeenCalled();
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          layout: expect.any(Object),
          content: expect.any(Object),
          interaction: expect.any(Object),
        })
      );
    });

    it('should call listener immediately with current decision', () => {
      coordinator.start();
      coordinator.forceAdapt();
      
      const listener = vi.fn();
      coordinator.subscribe(listener);
      
      expect(listener).toHaveBeenCalledTimes(1);
    });

    it('should allow unsubscription', () => {
      const listener = vi.fn();
      coordinator.start();
      
      const unsubscribe = coordinator.subscribe(listener);
      listener.mockClear();
      
      unsubscribe();
      coordinator.forceAdapt();
      
      expect(listener).not.toHaveBeenCalled();
    });
  });

  describe('CSS variables', () => {
    it('should generate CSS variables', () => {
      coordinator = new AdaptationCoordinator({ 
        autoStart: true,
        generateCssVariables: true,
      });
      
      coordinator.forceAdapt();
      
      expect(mockSetProperty).toHaveBeenCalled();
      expect(mockSetProperty).toHaveBeenCalledWith(
        expect.stringContaining('--adaptive-spacing'),
        expect.any(String)
      );
    });

    it('should return CSS variables as object', () => {
      coordinator.start();
      coordinator.forceAdapt();
      
      const vars = coordinator.getCssVariablesObject();
      
      expect(vars['--adaptive-spacing-unit']).toBeDefined();
      expect(vars['--adaptive-grid-columns']).toBeDefined();
      expect(vars['--adaptive-density-scale']).toBeDefined();
    });
  });

  describe('overrides', () => {
    it('should apply user overrides', () => {
      const listener = vi.fn();
      coordinator.start();
      coordinator.subscribe(listener);
      
      coordinator.setOverride('layout.density', 'compact');
      
      expect(listener).toHaveBeenCalled();
    });

    it('should clear overrides', () => {
      coordinator.start();
      coordinator.setOverride('layout.density', 'compact');
      coordinator.clearOverride('layout.density');
      
      // Should not throw
      expect(coordinator.getCurrentDecision()).toBeDefined();
    });

    it('should clear all overrides', () => {
      coordinator.start();
      coordinator.setOverride('layout.density', 'compact');
      coordinator.setOverride('layout.gridColumns', 8);
      
      coordinator.clearAllOverrides();
      
      // Should not throw
      expect(coordinator.getCurrentDecision()).toBeDefined();
    });
  });
});

