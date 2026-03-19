/**
 * Adaptive UI Architecture — Modeling Service Tests
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';

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

// Import after mocking
import { ModelingServiceImpl } from '../core/modeling/modeling-service';
import type { InteractionEvent } from '../core/capture/types';

function createEvent(
  overrides: Partial<InteractionEvent> = {}
): InteractionEvent {
  return {
    id: `event-${Math.random().toString(36).slice(2)}`,
    type: 'click',
    timestamp: new Date(),
    target: 'button-1',
    componentType: 'button',
    componentId: 'main-cta',
    metadata: {},
    sessionId: 'session-1',
    ...overrides,
  };
}

describe('ModelingService', () => {
  let service: ModelingServiceImpl;

  beforeEach(() => {
    localStorageMock.clear();
    service = new ModelingServiceImpl();
  });

  describe('getOrCreateModel()', () => {
    it('should create default model for new user', () => {
      const model = service.getOrCreateModel('user-123');
      
      expect(model.userId).toBe('user-123');
      expect(model.interactionCount).toBe(0);
      expect(model.confidence).toBe(0);
      expect(model.layout.density).toBe('comfortable');
      expect(model.expertise.level).toBe('novice');
    });

    it('should return existing model', () => {
      const model1 = service.getOrCreateModel('user-123');
      model1.interactionCount = 100;
      
      const model2 = service.getOrCreateModel('user-123');
      expect(model2.interactionCount).toBe(100);
    });
  });

  describe('updateModel()', () => {
    it('should update interaction count', () => {
      const events = [
        createEvent({ type: 'click' }),
        createEvent({ type: 'filter' }),
        createEvent({ type: 'sort' }),
      ];
      
      service.updateModel('user-123', events);
      
      const model = service.getModel('user-123');
      expect(model?.interactionCount).toBe(3);
    });

    it('should infer table sort preferences', () => {
      const events = [
        createEvent({
          type: 'sort',
          componentType: 'table',
          componentId: 'data-table',
          metadata: { column: 'date', direction: 'desc' },
        }),
        createEvent({
          type: 'sort',
          componentType: 'table',
          componentId: 'data-table',
          metadata: { column: 'date', direction: 'desc' },
        }),
      ];
      
      service.updateModel('user-123', events);
      
      const model = service.getModel('user-123');
      expect(model?.tables.defaultSort['data-table']).toEqual({
        column: 'date',
        direction: 'desc',
      });
    });

    it('should infer filter preferences', () => {
      const events = Array.from({ length: 5 }, () =>
        createEvent({
          type: 'filter',
          componentType: 'filter',
          componentId: 'status-filter',
          metadata: { field: 'status', value: 'active' },
        })
      );
      
      service.updateModel('user-123', events);
      
      const model = service.getModel('user-123');
      const statusFilters = model?.filters.frequentFilters['status-filter'];
      expect(statusFilters).toBeDefined();
      expect(statusFilters?.some(f => f.field === 'status' && f.value === 'active')).toBe(true);
    });

    it('should update confidence based on data', () => {
      // Small dataset = low confidence
      service.updateModel('user-123', [createEvent()]);
      let model = service.getModel('user-123');
      expect(model?.confidence).toBeLessThan(0.3);
      
      // Larger dataset = higher confidence
      const manyEvents = Array.from({ length: 100 }, () => createEvent());
      service.updateModel('user-123', manyEvents);
      model = service.getModel('user-123');
      expect(model?.confidence).toBeGreaterThan(0.2);
    });
  });

  describe('expertise inference', () => {
    it('should detect keyboard power user', () => {
      const events = Array.from({ length: 30 }, () =>
        createEvent({
          type: 'click',
          metadata: { triggeredBy: 'keyboard', shortcut: 'Ctrl+S' },
        })
      );
      
      service.updateModel('user-123', events);
      
      const model = service.getModel('user-123');
      expect(model?.navigation.usesKeyboardShortcuts).toBe(true);
    });

    it('should track feature familiarity', () => {
      const events = [
        ...Array.from({ length: 10 }, () => createEvent({ componentType: 'filter' })),
        ...Array.from({ length: 5 }, () => createEvent({ componentType: 'chart' })),
      ];
      
      service.updateModel('user-123', events);
      
      const model = service.getModel('user-123');
      expect(model?.expertise.featureFamiliarity['filter']).toBeGreaterThan(0);
      expect(model?.expertise.featureFamiliarity['chart']).toBeGreaterThan(0);
    });
  });
});

