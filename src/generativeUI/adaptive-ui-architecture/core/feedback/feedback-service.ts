/**
 * Adaptive UI Architecture — Feedback Service
 * 
 * Collects explicit user feedback on adaptations to refine models.
 */

import type { 
  FeedbackService, 
  FeedbackEvent, 
  FeedbackPrompt, 
  FeedbackSentiment,
  FeedbackTrigger 
} from './types';
import { contextProvider } from '../context/context-provider';

// ============================================================================
// STORAGE
// ============================================================================

const FEEDBACK_STORAGE_KEY = 'adaptive-ui-feedback';
const PROMPTS_SHOWN_KEY = 'adaptive-ui-prompts-shown';

// ============================================================================
// DEFAULT PROMPTS
// ============================================================================

const defaultPrompts: FeedbackPrompt[] = [
  {
    id: 'layout-density',
    type: 'thumbs',
    question: 'Is this layout density comfortable for you?',
    trigger: { type: 'adaptation', adaptationType: 'layout', setting: 'density' },
    frequency: 'weekly',
    priority: 80,
  },
  {
    id: 'suggested-filters',
    type: 'thumbs',
    question: 'Were these filter suggestions helpful?',
    trigger: { type: 'adaptation', adaptationType: 'content', setting: 'suggestedFilters' },
    frequency: 'daily',
    priority: 70,
  },
  {
    id: 'page-size',
    type: 'choice',
    question: 'How many rows would you prefer to see?',
    options: [
      { id: '10', label: '10 rows', value: 10 },
      { id: '25', label: '25 rows', value: 25 },
      { id: '50', label: '50 rows', value: 50 },
      { id: '100', label: '100 rows', value: 100 },
    ],
    trigger: { type: 'first-use', feature: 'table-pagination' },
    frequency: 'once',
    priority: 60,
  },
  {
    id: 'low-confidence',
    type: 'rating',
    question: 'How well is the UI adapting to your preferences?',
    trigger: { type: 'confidence', below: 0.4 },
    frequency: 'weekly',
    priority: 90,
  },
];

// ============================================================================
// SERVICE IMPLEMENTATION
// ============================================================================

export class FeedbackServiceImpl implements FeedbackService {
  private feedbackHistory: FeedbackEvent[] = [];
  private promptsShown: Map<string, Date> = new Map();
  private listeners: Set<(event: FeedbackEvent) => void> = new Set();
  private prompts: FeedbackPrompt[] = [...defaultPrompts];
  
  constructor() {
    this.loadFromStorage();
  }
  
  private loadFromStorage(): void {
    if (typeof localStorage === 'undefined') return;
    
    try {
      const feedbackRaw = localStorage.getItem(FEEDBACK_STORAGE_KEY);
      if (feedbackRaw) {
        const parsed = JSON.parse(feedbackRaw);
        this.feedbackHistory = parsed.map((f: FeedbackEvent) => ({
          ...f,
          timestamp: new Date(f.timestamp),
        }));
      }
      
      const promptsRaw = localStorage.getItem(PROMPTS_SHOWN_KEY);
      if (promptsRaw) {
        const parsed = JSON.parse(promptsRaw);
        this.promptsShown = new Map(
          Object.entries(parsed).map(([k, v]) => [k, new Date(v as string)])
        );
      }
    } catch (e) {
      console.error('[FeedbackService] Failed to load:', e);
    }
  }
  
  private saveToStorage(): void {
    if (typeof localStorage === 'undefined') return;
    
    try {
      localStorage.setItem(FEEDBACK_STORAGE_KEY, JSON.stringify(this.feedbackHistory));
      
      const promptsObj: Record<string, string> = {};
      this.promptsShown.forEach((date, key) => {
        promptsObj[key] = date.toISOString();
      });
      localStorage.setItem(PROMPTS_SHOWN_KEY, JSON.stringify(promptsObj));
    } catch (e) {
      console.error('[FeedbackService] Failed to save:', e);
    }
  }
  
  // ============================================================================
  // PUBLIC API
  // ============================================================================
  
  recordFeedback(feedback: Omit<FeedbackEvent, 'id' | 'timestamp'>): void {
    const event: FeedbackEvent = {
      ...feedback,
      id: `fb-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      timestamp: new Date(),
    };
    
    this.feedbackHistory.push(event);
    
    // Keep only last 500 events
    if (this.feedbackHistory.length > 500) {
      this.feedbackHistory = this.feedbackHistory.slice(-500);
    }
    
    this.saveToStorage();
    this.notifyListeners(event);
  }
  
  getFeedbackHistory(userId: string, limit = 50): FeedbackEvent[] {
    return this.feedbackHistory
      .filter(f => f.userId === userId)
      .slice(-limit);
  }
  
  getAdaptationFeedback(setting: string): {
    positive: number;
    negative: number;
    neutral: number;
    averageRating?: number;
  } {
    const relevant = this.feedbackHistory.filter(f => f.setting === setting);
    
    const positive = relevant.filter(f => f.sentiment === 'positive').length;
    const negative = relevant.filter(f => f.sentiment === 'negative').length;
    const neutral = relevant.filter(f => f.sentiment === 'neutral').length;
    
    const ratings = relevant.filter(f => f.rating !== undefined).map(f => f.rating!);
    const averageRating = ratings.length > 0
      ? ratings.reduce((a, b) => a + b, 0) / ratings.length
      : undefined;

    return { positive, negative, neutral, averageRating };
  }

  shouldPromptFeedback(userId: string, adaptationType: string): boolean {
    // Check if any prompts are pending for this adaptation type
    const pending = this.getPendingPrompts(userId);
    return pending.some(p => {
      if (p.trigger.type === 'adaptation') {
        return p.trigger.adaptationType === adaptationType;
      }
      return false;
    });
  }

  getPendingPrompts(userId: string): FeedbackPrompt[] {
    const now = new Date();
    const ctx = contextProvider.getContext();

    return this.prompts.filter(prompt => {
      // Check frequency
      const key = `${userId}:${prompt.id}`;
      const lastShown = this.promptsShown.get(key);

      if (lastShown) {
        const daysSince = (now.getTime() - lastShown.getTime()) / (1000 * 60 * 60 * 24);

        switch (prompt.frequency) {
          case 'once': return false;
          case 'daily': if (daysSince < 1) return false; break;
          case 'weekly': if (daysSince < 7) return false; break;
        }
      }

      // Check trigger conditions
      if (prompt.trigger.type === 'confidence') {
        return ctx.confidence < prompt.trigger.below;
      }

      return true;
    }).sort((a, b) => b.priority - a.priority);
  }

  dismissPrompt(userId: string, promptId: string): void {
    const key = `${userId}:${promptId}`;
    this.promptsShown.set(key, new Date());
    this.saveToStorage();
  }

  subscribe(listener: (event: FeedbackEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private notifyListeners(event: FeedbackEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (e) {
        console.error('[FeedbackService] Listener error:', e);
      }
    }
  }

  /** Add a custom feedback prompt */
  addPrompt(prompt: FeedbackPrompt): void {
    this.prompts.push(prompt);
  }

  /** Get all feedback for analysis */
  getAllFeedback(): FeedbackEvent[] {
    return [...this.feedbackHistory];
  }

  /** Clear all feedback (for testing/reset) */
  clearAll(): void {
    this.feedbackHistory = [];
    this.promptsShown.clear();
    this.saveToStorage();
  }
}

// Singleton instance
export const feedbackService = new FeedbackServiceImpl();

