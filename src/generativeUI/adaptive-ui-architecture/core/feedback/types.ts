/**
 * Adaptive UI Architecture — Feedback Types
 * 
 * Types for collecting explicit user feedback on adaptations.
 */

// ============================================================================
// FEEDBACK TYPES
// ============================================================================

export type FeedbackType = 
  | 'thumbs'        // Simple thumbs up/down
  | 'rating'        // 1-5 star rating
  | 'choice'        // A/B choice between options
  | 'correction'    // User corrects an adaptation
  | 'dismiss';      // User dismisses/ignores suggestion

export type FeedbackSentiment = 'positive' | 'negative' | 'neutral';

export interface FeedbackEvent {
  id: string;
  type: FeedbackType;
  timestamp: Date;
  userId: string;
  
  /** What adaptation triggered this feedback */
  adaptationId: string;
  adaptationType: 'layout' | 'content' | 'interaction' | 'predictive';
  
  /** The specific setting that was adapted */
  setting: string;
  
  /** What value was shown to the user */
  adaptedValue: unknown;
  
  /** User's feedback */
  sentiment: FeedbackSentiment;
  rating?: number;           // For rating type (1-5)
  preferredValue?: unknown;  // For correction type
  comment?: string;          // Optional user comment
  
  /** Context at time of feedback */
  context: {
    deviceType: string;
    screenWidth: number;
    taskMode: string;
    confidence: number;      // Model confidence when adaptation was made
  };
}

// ============================================================================
// FEEDBACK PROMPTS
// ============================================================================

export interface FeedbackPrompt {
  id: string;
  type: FeedbackType;
  
  /** What to ask the user */
  question: string;
  
  /** Options for choice type */
  options?: Array<{
    id: string;
    label: string;
    value: unknown;
  }>;
  
  /** When to show this prompt */
  trigger: FeedbackTrigger;
  
  /** How often to show (prevent fatigue) */
  frequency: 'once' | 'daily' | 'weekly' | 'always';
  
  /** Priority for display (higher = more important) */
  priority: number;
}

export type FeedbackTrigger =
  | { type: 'adaptation'; adaptationType: string; setting: string }
  | { type: 'session'; afterMinutes: number }
  | { type: 'confidence'; below: number }
  | { type: 'first-use'; feature: string };

// ============================================================================
// FEEDBACK SERVICE
// ============================================================================

export interface FeedbackService {
  /** Record user feedback */
  recordFeedback(feedback: Omit<FeedbackEvent, 'id' | 'timestamp'>): void;
  
  /** Get feedback history for a user */
  getFeedbackHistory(userId: string, limit?: number): FeedbackEvent[];
  
  /** Get aggregate feedback for an adaptation setting */
  getAdaptationFeedback(setting: string): {
    positive: number;
    negative: number;
    neutral: number;
    averageRating?: number;
  };
  
  /** Check if user should be prompted for feedback */
  shouldPromptFeedback(userId: string, adaptationType: string): boolean;
  
  /** Get pending feedback prompts for user */
  getPendingPrompts(userId: string): FeedbackPrompt[];
  
  /** Mark a prompt as shown/dismissed */
  dismissPrompt(userId: string, promptId: string): void;
  
  /** Subscribe to feedback events */
  subscribe(listener: (event: FeedbackEvent) => void): () => void;
}

// ============================================================================
// MODEL REFINEMENT
// ============================================================================

export interface RefinementSuggestion {
  setting: string;
  currentValue: unknown;
  suggestedValue: unknown;
  confidence: number;
  reason: string;
  feedbackCount: number;
}

export interface ModelRefinementService {
  /** Analyze feedback and suggest model refinements */
  analyzeFeedback(userId: string): RefinementSuggestion[];
  
  /** Apply a refinement to the user model */
  applyRefinement(userId: string, suggestion: RefinementSuggestion): void;
  
  /** Auto-apply refinements above confidence threshold */
  autoRefine(userId: string, minConfidence?: number): number;
}

