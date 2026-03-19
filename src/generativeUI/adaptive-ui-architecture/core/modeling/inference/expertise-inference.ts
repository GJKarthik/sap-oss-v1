/**
 * Adaptive UI Architecture — Expertise Inference
 * 
 * Sophisticated inference of user expertise level from behavior patterns.
 */

import type { ExpertiseModel } from '../types';
import type { InteractionEvent } from '../../capture/types';

// ============================================================================
// EXPERTISE SIGNALS
// ============================================================================

interface ExpertiseSignal {
  name: string;
  weight: number;
  evaluate: (events: InteractionEvent[]) => number; // 0-1 score
}

const expertiseSignals: ExpertiseSignal[] = [
  {
    name: 'keyboard_shortcuts',
    weight: 0.25,
    evaluate: (events) => {
      const keyboardEvents = events.filter(
        e => e.metadata.triggeredBy === 'keyboard' || e.metadata.shortcut
      );
      return Math.min(keyboardEvents.length / events.length * 2, 1);
    },
  },
  {
    name: 'advanced_features',
    weight: 0.2,
    evaluate: (events) => {
      const advancedTypes = ['export', 'undo', 'redo', 'drag', 'drop'];
      const advanced = events.filter(e => advancedTypes.includes(e.type));
      return Math.min(advanced.length / Math.max(events.length, 1) * 5, 1);
    },
  },
  {
    name: 'task_velocity',
    weight: 0.2,
    evaluate: (events) => {
      // Experts complete tasks faster
      if (events.length < 5) return 0.5;
      
      // Calculate average time between meaningful actions
      const actionEvents = events.filter(e => 
        ['click', 'select', 'filter', 'sort'].includes(e.type)
      );
      
      if (actionEvents.length < 2) return 0.5;
      
      const times = actionEvents.map(e => new Date(e.timestamp).getTime());
      let totalGap = 0;
      for (let i = 1; i < times.length; i++) {
        totalGap += times[i] - times[i - 1];
      }
      const avgGap = totalGap / (times.length - 1);
      
      // Fast: < 2s, Slow: > 10s
      if (avgGap < 2000) return 1;
      if (avgGap > 10000) return 0;
      return 1 - (avgGap - 2000) / 8000;
    },
  },
  {
    name: 'exploration_depth',
    weight: 0.15,
    evaluate: (events) => {
      // Experts explore more features
      const uniqueComponents = new Set(events.map(e => e.componentType)).size;
      const uniqueActions = new Set(events.map(e => e.type)).size;
      
      const componentScore = Math.min(uniqueComponents / 10, 1);
      const actionScore = Math.min(uniqueActions / 8, 1);
      
      return (componentScore + actionScore) / 2;
    },
  },
  {
    name: 'error_recovery',
    weight: 0.1,
    evaluate: (events) => {
      // Experts use undo/redo more effectively
      const undos = events.filter(e => e.type === 'undo').length;
      const redos = events.filter(e => e.type === 'redo').length;
      
      // Having some undos is good (exploring), too many is bad (confusion)
      const undoRatio = undos / Math.max(events.length, 1);
      
      if (undoRatio > 0.1) return 0.3; // Too many mistakes
      if (undoRatio > 0.02) return 1; // Using undo effectively
      return 0.5; // Not using undo at all
    },
  },
  {
    name: 'filter_complexity',
    weight: 0.1,
    evaluate: (events) => {
      // Experts use more complex filters
      const filterEvents = events.filter(e => e.type === 'filter');
      
      // Check for multiple filter combinations
      const filterSessions: InteractionEvent[][] = [];
      let currentSession: InteractionEvent[] = [];
      
      for (const event of filterEvents) {
        if (currentSession.length === 0) {
          currentSession.push(event);
        } else {
          const lastTime = new Date(currentSession[currentSession.length - 1].timestamp).getTime();
          const thisTime = new Date(event.timestamp).getTime();
          
          if (thisTime - lastTime < 5000) {
            currentSession.push(event);
          } else {
            filterSessions.push(currentSession);
            currentSession = [event];
          }
        }
      }
      if (currentSession.length > 0) {
        filterSessions.push(currentSession);
      }
      
      // Average filters per session
      const avgFilters = filterSessions.length > 0
        ? filterSessions.reduce((sum, s) => sum + s.length, 0) / filterSessions.length
        : 0;
      
      return Math.min(avgFilters / 3, 1);
    },
  },
];

// ============================================================================
// INFERENCE FUNCTION
// ============================================================================

export function inferDetailedExpertise(
  events: InteractionEvent[],
  current: ExpertiseModel
): ExpertiseModel {
  if (events.length < 10) {
    // Not enough data, increase confidence slightly but don't change level
    return {
      ...current,
      confidence: Math.min(current.confidence + 0.05, 0.3),
    };
  }
  
  // Calculate weighted expertise score
  let totalScore = 0;
  let totalWeight = 0;
  const signalResults: Record<string, number> = {};
  
  for (const signal of expertiseSignals) {
    const score = signal.evaluate(events);
    signalResults[signal.name] = score;
    totalScore += score * signal.weight;
    totalWeight += signal.weight;
  }
  
  const expertiseScore = totalScore / totalWeight;
  
  // Determine level with hysteresis (avoid flip-flopping)
  let level: 'novice' | 'intermediate' | 'expert' = current.level;
  
  if (expertiseScore > 0.7 && current.level !== 'expert') {
    level = 'expert';
  } else if (expertiseScore > 0.4 && expertiseScore <= 0.7 && current.level === 'novice') {
    level = 'intermediate';
  } else if (expertiseScore < 0.3 && current.level !== 'novice') {
    level = 'intermediate'; // Don't drop directly to novice
  } else if (expertiseScore < 0.2) {
    level = 'novice';
  }
  
  // Update feature familiarity
  const featureFamiliarity = { ...current.featureFamiliarity };
  for (const event of events) {
    const feature = event.componentType;
    const currentVal = featureFamiliarity[feature] || 0;
    // Decay existing + add new observation
    featureFamiliarity[feature] = Math.min(currentVal * 0.95 + 0.1, 1);
  }
  
  // Determine learning velocity
  const recentFamiliarity = Object.values(featureFamiliarity);
  const avgFamiliarity = recentFamiliarity.length > 0
    ? recentFamiliarity.reduce((a, b) => a + b, 0) / recentFamiliarity.length
    : 0;
  
  let learningVelocity: 'slow' | 'moderate' | 'fast' = 'moderate';
  if (avgFamiliarity > 0.7) learningVelocity = 'fast';
  else if (avgFamiliarity < 0.3) learningVelocity = 'slow';
  
  // Confidence increases with more data, up to 0.95
  const dataConfidence = Math.min(events.length / 200, 0.5);
  const confidence = Math.min(current.confidence * 0.8 + dataConfidence + 0.2, 0.95);
  
  return {
    ...current,
    level,
    confidence,
    featureFamiliarity,
    learningVelocity,
  };
}

