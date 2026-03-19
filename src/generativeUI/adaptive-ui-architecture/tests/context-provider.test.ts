/**
 * Adaptive UI Architecture — Context Provider Tests
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';

// Mock window and matchMedia
const mockMatchMedia = vi.fn().mockImplementation((query: string) => ({
  matches: false,
  media: query,
  onchange: null,
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
}));

const mockAddEventListener = vi.fn();
const mockNavigator = {
  language: 'en-US',
  maxTouchPoints: 0,
  connection: { effectiveType: '4g' },
};

Object.defineProperty(global, 'window', {
  value: {
    innerWidth: 1920,
    innerHeight: 1080,
    devicePixelRatio: 1,
    matchMedia: mockMatchMedia,
    addEventListener: mockAddEventListener,
  },
  writable: true,
});

Object.defineProperty(global, 'navigator', { value: mockNavigator, writable: true });
Object.defineProperty(global, 'document', { 
  value: { 
    addEventListener: vi.fn(),
    visibilityState: 'visible',
  }, 
  writable: true,
});
Object.defineProperty(global, 'localStorage', {
  value: {
    getItem: vi.fn().mockReturnValue(null),
    setItem: vi.fn(),
    removeItem: vi.fn(),
  },
  writable: true,
});

// Import after mocking
import { ContextProvider } from '../core/context/context-provider';
import type { UserContext, TaskMode } from '../core/context/types';

describe('ContextProvider', () => {
  let provider: ContextProvider;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-03-19T14:30:00'));
    provider = new ContextProvider();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('getContext()', () => {
    it('should return a complete context object', () => {
      const ctx = provider.getContext();
      
      expect(ctx).toHaveProperty('user');
      expect(ctx).toHaveProperty('task');
      expect(ctx).toHaveProperty('temporal');
      expect(ctx).toHaveProperty('device');
      expect(ctx).toHaveProperty('data');
      expect(ctx).toHaveProperty('generatedAt');
      expect(ctx).toHaveProperty('confidence');
    });

    it('should return anonymous user when not set', () => {
      const ctx = provider.getContext();
      
      expect(ctx.user.userId).toBe('anonymous');
      expect(ctx.user.role.permissionLevel).toBe('viewer');
    });

    it('should detect temporal context correctly', () => {
      const ctx = provider.getContext();
      
      // 14:30 is afternoon
      expect(ctx.temporal.timeOfDay).toBe('afternoon');
      // March 19 2026 is a Thursday
      expect(ctx.temporal.dayType).toBe('weekday');
    });

    it('should detect device context', () => {
      const ctx = provider.getContext();
      
      expect(ctx.device.type).toBe('desktop'); // 1920px width
      expect(ctx.device.screenWidth).toBe(1920);
      expect(ctx.device.screenHeight).toBe(1080);
    });
  });

  describe('setUserContext()', () => {
    it('should set user context', () => {
      const user: UserContext = {
        userId: 'user-123',
        role: { 
          id: 'admin', 
          name: 'Administrator', 
          permissionLevel: 'admin',
          expertiseLevel: 'expert',
        },
        organization: 'SAP',
        locale: 'de-DE',
        timezone: 'Europe/Berlin',
      };

      provider.setUserContext(user);
      const ctx = provider.getContext();

      expect(ctx.user.userId).toBe('user-123');
      expect(ctx.user.role.permissionLevel).toBe('admin');
      expect(ctx.confidence).toBe(0.9);
    });
  });

  describe('setTaskMode()', () => {
    it('should update task mode', () => {
      provider.setTaskMode('analyze');
      const ctx = provider.getContext();
      
      expect(ctx.task.mode).toBe('analyze');
    });

    it('should notify subscribers on mode change', () => {
      const listener = vi.fn();
      provider.subscribe(listener);
      
      // Clear initial call
      listener.mockClear();
      
      provider.setTaskMode('execute');
      
      expect(listener).toHaveBeenCalledTimes(1);
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          task: expect.objectContaining({ mode: 'execute' }),
        })
      );
    });
  });

  describe('workflow management', () => {
    it('should track workflow state', () => {
      provider.enterWorkflow(5);
      let ctx = provider.getContext();
      
      expect(ctx.task.inWorkflow).toBe(true);
      expect(ctx.task.workflowStep).toBe(1);
      expect(ctx.task.workflowTotalSteps).toBe(5);

      provider.advanceWorkflow();
      ctx = provider.getContext();
      expect(ctx.task.workflowStep).toBe(2);

      provider.exitWorkflow();
      ctx = provider.getContext();
      expect(ctx.task.inWorkflow).toBe(false);
      expect(ctx.task.workflowStep).toBeUndefined();
    });
  });

  describe('subscribe()', () => {
    it('should call listener with current context immediately', () => {
      const listener = vi.fn();
      provider.subscribe(listener);
      
      expect(listener).toHaveBeenCalledTimes(1);
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          user: expect.any(Object),
          task: expect.any(Object),
        })
      );
    });

    it('should return unsubscribe function', () => {
      const listener = vi.fn();
      const unsubscribe = provider.subscribe(listener);
      
      listener.mockClear();
      unsubscribe();
      
      provider.setTaskMode('execute');
      
      expect(listener).not.toHaveBeenCalled();
    });
  });

  describe('session management', () => {
    it('should generate unique session ID', () => {
      const sessionId = provider.getSessionId();
      expect(sessionId).toMatch(/^session-\d+-[a-z0-9]+$/);
    });

    it('should calculate session duration', () => {
      // Advance time by 30 minutes
      vi.advanceTimersByTime(30 * 60 * 1000);
      
      const ctx = provider.getContext();
      expect(ctx.temporal.sessionDurationMinutes).toBe(30);
    });
  });
});

