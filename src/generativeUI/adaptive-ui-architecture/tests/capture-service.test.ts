/**
 * Adaptive UI Architecture — Capture Service Tests
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
import { CaptureServiceImpl } from '../core/capture/capture-service';
import type { InteractionEvent } from '../core/capture/types';

describe('CaptureService', () => {
  let service: CaptureServiceImpl;

  beforeEach(() => {
    localStorageMock.clear();
    service = new CaptureServiceImpl();
  });

  describe('capture()', () => {
    it('should capture click events', () => {
      service.capture({
        type: 'click',
        target: 'button-1',
        componentType: 'button',
        componentId: 'main-cta',
        metadata: { label: 'Submit' },
      });

      const events = service.export();
      expect(events).toHaveLength(1);
      expect(events[0].type).toBe('click');
      expect(events[0].target).toBe('button-1');
      expect(events[0].componentId).toBe('main-cta');
    });

    it('should generate unique IDs', () => {
      service.capture({
        type: 'click',
        target: 'btn-1',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });
      service.capture({
        type: 'click',
        target: 'btn-2',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });

      const events = service.export();
      expect(events[0].id).not.toBe(events[1].id);
    });

    it('should include timestamp', () => {
      const before = new Date();
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });

      const after = new Date();
      const events = service.export();
      
      expect(events[0].timestamp.getTime()).toBeGreaterThanOrEqual(before.getTime());
      expect(events[0].timestamp.getTime()).toBeLessThanOrEqual(after.getTime());
    });
  });

  describe('filtering', () => {
    beforeEach(() => {
      // Add various events
      service.capture({ type: 'click', target: 'btn', componentType: 'button', componentId: 'btn-1', metadata: {} });
      service.capture({ type: 'filter', target: 'field', componentType: 'filter', componentId: 'filter-1', metadata: {} });
      service.capture({ type: 'sort', target: 'col', componentType: 'table', componentId: 'table-1', metadata: {} });
      service.capture({ type: 'click', target: 'btn', componentType: 'button', componentId: 'btn-1', metadata: {} });
    });

    it('should filter by event type', () => {
      const clicks = service.getEventsByType('click');
      expect(clicks).toHaveLength(2);
      expect(clicks.every(e => e.type === 'click')).toBe(true);
    });

    it('should filter by component ID', () => {
      const btnEvents = service.getEventsForComponent('btn-1');
      expect(btnEvents).toHaveLength(2);
      expect(btnEvents.every(e => e.componentId === 'btn-1')).toBe(true);
    });
  });

  describe('configuration', () => {
    it('should respect enabled setting', () => {
      service.configure({ enabled: false });
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });

      expect(service.export()).toHaveLength(0);
    });

    it('should exclude specified components', () => {
      service.configure({ excludedComponents: ['password', 'secret'] });
      
      service.capture({
        type: 'click',
        target: 'password-input',
        componentType: 'input',
        componentId: 'password-field',
        metadata: {},
      });

      expect(service.export()).toHaveLength(0);
    });

    it('should only capture specified event types', () => {
      service.configure({ capturedEvents: ['click'] });
      
      service.capture({ type: 'click', target: 'btn', componentType: 'button', componentId: 'btn', metadata: {} });
      service.capture({ type: 'filter', target: 'field', componentType: 'filter', componentId: 'filter', metadata: {} });

      const events = service.export();
      expect(events).toHaveLength(1);
      expect(events[0].type).toBe('click');
    });
  });

  describe('anonymization', () => {
    it('should anonymize sensitive fields in partial mode', () => {
      service.configure({ anonymizationLevel: 'partial' });
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: { 
          userEmail: 'test@example.com',
          label: 'Submit',
        },
      });

      const events = service.export();
      expect(events[0].metadata.label).toBe('Submit');
      expect(events[0].metadata.userEmail).toBeUndefined();
    });

    it('should remove all metadata in full mode', () => {
      service.configure({ anonymizationLevel: 'full' });
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: { label: 'Submit', action: 'save' },
      });

      const events = service.export();
      expect(Object.keys(events[0].metadata)).toHaveLength(0);
    });
  });

  describe('subscription', () => {
    it('should notify subscribers of new events', () => {
      const listener = vi.fn();
      service.subscribe(listener);
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });

      expect(listener).toHaveBeenCalledTimes(1);
      expect(listener).toHaveBeenCalledWith(expect.objectContaining({ type: 'click' }));
    });

    it('should allow unsubscribing', () => {
      const listener = vi.fn();
      const unsubscribe = service.subscribe(listener);
      
      unsubscribe();
      
      service.capture({
        type: 'click',
        target: 'btn',
        componentType: 'button',
        componentId: 'btn',
        metadata: {},
      });

      expect(listener).not.toHaveBeenCalled();
    });
  });
});

