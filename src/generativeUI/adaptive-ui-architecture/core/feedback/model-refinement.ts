/**
 * Adaptive UI Architecture — Model Refinement Service
 * 
 * Analyzes feedback to suggest and apply model improvements.
 */

import type { ModelRefinementService, RefinementSuggestion, FeedbackEvent } from './types';
import { feedbackService } from './feedback-service';
import { modelingService } from '../modeling/modeling-service';

// ============================================================================
// REFINEMENT THRESHOLDS
// ============================================================================

const MIN_FEEDBACK_COUNT = 3;       // Need at least 3 feedbacks to suggest
const POSITIVE_THRESHOLD = 0.7;     // 70% positive = good adaptation
const NEGATIVE_THRESHOLD = 0.5;     // 50% negative = needs change
const AUTO_APPLY_CONFIDENCE = 0.85; // Auto-apply above 85% confidence

// ============================================================================
// SERVICE IMPLEMENTATION
// ============================================================================

export class ModelRefinementServiceImpl implements ModelRefinementService {
  
  analyzeFeedback(userId: string): RefinementSuggestion[] {
    const suggestions: RefinementSuggestion[] = [];
    const feedback = feedbackService.getFeedbackHistory(userId, 200);
    
    if (feedback.length === 0) return suggestions;
    
    // Group feedback by setting
    const bySettings = new Map<string, FeedbackEvent[]>();
    for (const event of feedback) {
      const existing = bySettings.get(event.setting) || [];
      existing.push(event);
      bySettings.set(event.setting, existing);
    }
    
    // Analyze each setting
    for (const [setting, events] of bySettings) {
      if (events.length < MIN_FEEDBACK_COUNT) continue;
      
      const suggestion = this.analyzeSettingFeedback(setting, events);
      if (suggestion) {
        suggestions.push(suggestion);
      }
    }
    
    return suggestions.sort((a, b) => b.confidence - a.confidence);
  }
  
  private analyzeSettingFeedback(
    setting: string, 
    events: FeedbackEvent[]
  ): RefinementSuggestion | null {
    const total = events.length;
    const positive = events.filter(e => e.sentiment === 'positive').length;
    const negative = events.filter(e => e.sentiment === 'negative').length;
    
    const positiveRatio = positive / total;
    const negativeRatio = negative / total;
    
    // If mostly positive, no change needed
    if (positiveRatio >= POSITIVE_THRESHOLD) {
      return null;
    }
    
    // If high negative ratio, suggest change
    if (negativeRatio >= NEGATIVE_THRESHOLD) {
      // Look for corrections (user-provided preferred values)
      const corrections = events
        .filter(e => e.preferredValue !== undefined)
        .map(e => e.preferredValue);
      
      if (corrections.length > 0) {
        // Use most common correction
        const valueCounts = new Map<string, number>();
        for (const val of corrections) {
          const key = JSON.stringify(val);
          valueCounts.set(key, (valueCounts.get(key) || 0) + 1);
        }
        
        let bestValue: unknown = undefined;
        let bestCount = 0;
        for (const [key, count] of valueCounts) {
          if (count > bestCount) {
            bestCount = count;
            bestValue = JSON.parse(key);
          }
        }
        
        if (bestValue !== undefined) {
          const mostRecent = events[events.length - 1];
          return {
            setting,
            currentValue: mostRecent.adaptedValue,
            suggestedValue: bestValue,
            confidence: bestCount / corrections.length,
            reason: `${bestCount} users corrected to this value`,
            feedbackCount: total,
          };
        }
      }
      
      // No corrections available, just note the issue
      const mostRecent = events[events.length - 1];
      return {
        setting,
        currentValue: mostRecent.adaptedValue,
        suggestedValue: null, // Unknown what to change to
        confidence: negativeRatio,
        reason: `${Math.round(negativeRatio * 100)}% negative feedback`,
        feedbackCount: total,
      };
    }
    
    return null;
  }
  
  applyRefinement(userId: string, suggestion: RefinementSuggestion): void {
    if (suggestion.suggestedValue === null) {
      console.warn('[ModelRefinement] Cannot apply: no suggested value');
      return;
    }
    
    const model = modelingService.getModel(userId);
    if (!model) return;
    
    // Apply the refinement based on setting type
    this.applySettingChange(userId, suggestion.setting, suggestion.suggestedValue);
  }
  
  private applySettingChange(userId: string, setting: string, value: unknown): void {
    const model = modelingService.getOrCreateModel(userId);
    
    // Parse setting path (e.g., "layout.density" or "tables.pageSize")
    const parts = setting.split('.');
    
    if (parts[0] === 'layout' && parts[1] === 'density') {
      model.layout.density = value as 'compact' | 'comfortable' | 'spacious';
      model.layout.densityConfidence = 0.9; // High confidence from feedback
    } else if (parts[0] === 'tables' && parts[1] === 'pageSize') {
      model.tables.pageSize = value as number;
    } else if (parts[0] === 'filters' && parts[1] === 'autoApply') {
      model.filters.autoApply = value as boolean;
    }
    
    // Note: In a real implementation, use modelingService.importModel()
    // to persist the change
  }
  
  autoRefine(userId: string, minConfidence = AUTO_APPLY_CONFIDENCE): number {
    const suggestions = this.analyzeFeedback(userId);
    let applied = 0;
    
    for (const suggestion of suggestions) {
      if (suggestion.confidence >= minConfidence && suggestion.suggestedValue !== null) {
        this.applyRefinement(userId, suggestion);
        applied++;
      }
    }
    
    return applied;
  }
}

// Singleton instance
export const modelRefinementService = new ModelRefinementServiceImpl();
