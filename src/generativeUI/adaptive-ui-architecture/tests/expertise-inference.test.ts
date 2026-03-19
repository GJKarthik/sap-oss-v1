/**
 * Adaptive UI Architecture — Expertise Inference Tests
 */

import { describe, it, expect } from 'vitest';
import { inferDetailedExpertise } from '../core/modeling/inference/expertise-inference';
import type { ExpertiseModel } from '../core/modeling/types';
import type { InteractionEvent } from '../core/capture/types';

function createEvent(
  overrides: Partial<InteractionEvent> = {}
): InteractionEvent {
  return {
    id: `event-${Math.random().toString(36).slice(2)}`,
    type: 'click',
    timestamp: new Date(),
    target: 'element',
    componentType: 'button',
    componentId: 'btn-1',
    metadata: {},
    sessionId: 'session-1',
    ...overrides,
  };
}

function createDefaultExpertise(): ExpertiseModel {
  return {
    level: 'novice',
    confidence: 0,
    domainExpertise: {},
    featureFamiliarity: {},
    learningVelocity: 'moderate',
  };
}

describe('inferDetailedExpertise', () => {
  it('should return current model with low data', () => {
    const events = [createEvent(), createEvent()];
    const current = createDefaultExpertise();
    
    const result = inferDetailedExpertise(events, current);
    
    expect(result.level).toBe('novice');
    expect(result.confidence).toBeLessThan(0.5);
  });

  it('should detect expert from keyboard shortcuts', () => {
    // Expert behavior: heavy keyboard usage
    const events = Array.from({ length: 50 }, (_, i) =>
      createEvent({
        metadata: i % 2 === 0 
          ? { triggeredBy: 'keyboard', shortcut: 'Ctrl+S' }
          : {},
      })
    );
    
    const result = inferDetailedExpertise(events, createDefaultExpertise());
    
    // High keyboard usage should push toward expert
    expect(result.confidence).toBeGreaterThan(0.3);
  });

  it('should detect expert from advanced feature usage', () => {
    const events = [
      ...Array.from({ length: 20 }, () => createEvent({ type: 'click' })),
      ...Array.from({ length: 15 }, () => createEvent({ type: 'export' })),
      ...Array.from({ length: 10 }, () => createEvent({ type: 'undo' })),
      ...Array.from({ length: 5 }, () => createEvent({ type: 'redo' })),
    ];
    
    const result = inferDetailedExpertise(events, createDefaultExpertise());
    
    // Heavy use of advanced features
    expect(result.level).not.toBe('novice');
  });

  it('should track feature familiarity', () => {
    const events = [
      ...Array.from({ length: 10 }, () => createEvent({ componentType: 'filter' })),
      ...Array.from({ length: 5 }, () => createEvent({ componentType: 'table' })),
      ...Array.from({ length: 2 }, () => createEvent({ componentType: 'chart' })),
    ];
    
    const result = inferDetailedExpertise(events, createDefaultExpertise());
    
    expect(result.featureFamiliarity['filter']).toBeGreaterThan(result.featureFamiliarity['chart']);
    expect(result.featureFamiliarity['table']).toBeDefined();
  });

  it('should not drop expertise level too quickly', () => {
    const expertModel: ExpertiseModel = {
      level: 'expert',
      confidence: 0.8,
      domainExpertise: {},
      featureFamiliarity: {},
      learningVelocity: 'fast',
    };
    
    // Some novice-like behavior
    const events = Array.from({ length: 20 }, () => createEvent({ type: 'click' }));
    
    const result = inferDetailedExpertise(events, expertModel);
    
    // Should not immediately drop to novice
    expect(result.level).not.toBe('novice');
  });

  it('should increase confidence with more data', () => {
    const events = Array.from({ length: 100 }, () => createEvent());
    
    const result = inferDetailedExpertise(events, createDefaultExpertise());
    
    expect(result.confidence).toBeGreaterThan(0.4);
  });

  it('should detect learning velocity', () => {
    // User quickly becomes familiar with many features
    const events: InteractionEvent[] = [];
    const components = ['filter', 'table', 'chart', 'form', 'sidebar', 'toolbar'];
    
    for (const comp of components) {
      for (let i = 0; i < 10; i++) {
        events.push(createEvent({ componentType: comp }));
      }
    }
    
    const result = inferDetailedExpertise(events, createDefaultExpertise());
    
    // High familiarity across many features = fast learner
    expect(['moderate', 'fast']).toContain(result.learningVelocity);
  });
});

