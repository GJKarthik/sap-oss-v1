/**
 * Adaptive UI Architecture — Feedback Widget
 * 
 * Collects user feedback on adaptations.
 * WCAG AA compliant with proper focus management.
 */

import React, { useState, useCallback, useRef, useEffect } from 'react';
import { feedbackService } from '../../core/feedback/feedback-service';
import { contextProvider } from '../../core/context/context-provider';
import type { FeedbackSentiment, FeedbackType } from '../../core/feedback/types';
import './FeedbackWidget.css';

// ============================================================================
// TYPES
// ============================================================================

export interface FeedbackWidgetProps {
  /** Unique ID for this feedback context */
  adaptationId: string;
  /** Type of adaptation being rated */
  adaptationType: 'layout' | 'content' | 'interaction' | 'predictive';
  /** Specific setting */
  setting: string;
  /** Current adapted value */
  adaptedValue: unknown;
  /** Type of feedback to collect */
  type?: FeedbackType;
  /** Question to display */
  question?: string;
  /** Callback after feedback submitted */
  onFeedback?: (sentiment: FeedbackSentiment) => void;
  /** Show inline or as popover */
  variant?: 'inline' | 'popover' | 'toast';
  /** Size */
  size?: 'small' | 'medium';
}

// ============================================================================
// THUMBS FEEDBACK
// ============================================================================

export function FeedbackWidget({
  adaptationId,
  adaptationType,
  setting,
  adaptedValue,
  type = 'thumbs',
  question = 'Was this helpful?',
  onFeedback,
  variant = 'inline',
  size = 'small',
}: FeedbackWidgetProps) {
  const [submitted, setSubmitted] = useState(false);
  const [selectedSentiment, setSelectedSentiment] = useState<FeedbackSentiment | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  
  const handleFeedback = useCallback((sentiment: FeedbackSentiment) => {
    const ctx = contextProvider.getContext();
    
    feedbackService.recordFeedback({
      type,
      userId: ctx.user.userId,
      adaptationId,
      adaptationType,
      setting,
      adaptedValue,
      sentiment,
      context: {
        deviceType: ctx.device.type,
        screenWidth: ctx.device.screenWidth,
        taskMode: ctx.task.mode,
        confidence: ctx.confidence,
      },
    });
    
    setSelectedSentiment(sentiment);
    setSubmitted(true);
    onFeedback?.(sentiment);
  }, [adaptationId, adaptationType, setting, adaptedValue, type, onFeedback]);

  if (submitted) {
    return (
      <div 
        className={`feedback-widget ${variant} ${size} submitted`}
        role="status"
        aria-live="polite"
      >
        <span className="feedback-thanks">
          {selectedSentiment === 'positive' ? '👍' : '👎'} Thanks for your feedback!
        </span>
      </div>
    );
  }

  return (
    <div 
      ref={containerRef}
      className={`feedback-widget ${variant} ${size}`}
      role="group"
      aria-label="Feedback"
    >
      <span className="feedback-question">{question}</span>
      
      <div className="feedback-buttons">
        <button
          className="feedback-btn positive"
          onClick={() => handleFeedback('positive')}
          aria-label="Yes, this was helpful"
          title="Yes"
        >
          <span aria-hidden="true">👍</span>
        </button>
        
        <button
          className="feedback-btn negative"
          onClick={() => handleFeedback('negative')}
          aria-label="No, this was not helpful"
          title="No"
        >
          <span aria-hidden="true">👎</span>
        </button>
      </div>
    </div>
  );
}

// ============================================================================
// RATING FEEDBACK
// ============================================================================

export interface RatingFeedbackProps extends Omit<FeedbackWidgetProps, 'type'> {
  maxRating?: number;
}

export function RatingFeedback({
  adaptationId,
  adaptationType,
  setting,
  adaptedValue,
  question = 'How would you rate this?',
  onFeedback,
  variant = 'inline',
  size = 'medium',
  maxRating = 5,
}: RatingFeedbackProps) {
  const [submitted, setSubmitted] = useState(false);
  const [rating, setRating] = useState<number | null>(null);
  const [hoveredRating, setHoveredRating] = useState<number | null>(null);
  
  const handleRating = useCallback((value: number) => {
    const ctx = contextProvider.getContext();
    const sentiment: FeedbackSentiment = 
      value >= 4 ? 'positive' : value <= 2 ? 'negative' : 'neutral';
    
    feedbackService.recordFeedback({
      type: 'rating',
      userId: ctx.user.userId,
      adaptationId,
      adaptationType,
      setting,
      adaptedValue,
      sentiment,
      rating: value,
      context: {
        deviceType: ctx.device.type,
        screenWidth: ctx.device.screenWidth,
        taskMode: ctx.task.mode,
        confidence: ctx.confidence,
      },
    });
    
    setRating(value);
    setSubmitted(true);
    onFeedback?.(sentiment);
  }, [adaptationId, adaptationType, setting, adaptedValue, onFeedback]);

  if (submitted) {
    return (
      <div
        className={`feedback-widget rating ${variant} ${size} submitted`}
        role="status"
        aria-live="polite"
      >
        <span className="feedback-thanks">
          Thanks! You rated {rating}/{maxRating}
        </span>
      </div>
    );
  }

  return (
    <div
      className={`feedback-widget rating ${variant} ${size}`}
      role="group"
      aria-label="Rating feedback"
    >
      <span className="feedback-question">{question}</span>

      <div className="rating-stars" role="radiogroup" aria-label="Rating">
        {Array.from({ length: maxRating }, (_, i) => i + 1).map(value => (
          <button
            key={value}
            className={`rating-star ${
              (hoveredRating ?? rating ?? 0) >= value ? 'filled' : ''
            }`}
            onClick={() => handleRating(value)}
            onMouseEnter={() => setHoveredRating(value)}
            onMouseLeave={() => setHoveredRating(null)}
            aria-label={`${value} star${value > 1 ? 's' : ''}`}
            role="radio"
            aria-checked={rating === value}
          >
            <span aria-hidden="true">{(hoveredRating ?? rating ?? 0) >= value ? '★' : '☆'}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

// ============================================================================
// CHOICE FEEDBACK (A/B Testing)
// ============================================================================

export interface ChoiceFeedbackProps extends Omit<FeedbackWidgetProps, 'type'> {
  options: Array<{
    id: string;
    label: string;
    value: unknown;
  }>;
}

export function ChoiceFeedback({
  adaptationId,
  adaptationType,
  setting,
  adaptedValue,
  question = 'Which do you prefer?',
  options,
  onFeedback,
  variant = 'inline',
  size = 'medium',
}: ChoiceFeedbackProps) {
  const [submitted, setSubmitted] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const handleChoice = useCallback((option: typeof options[0]) => {
    const ctx = contextProvider.getContext();
    const isCurrentValue = JSON.stringify(option.value) === JSON.stringify(adaptedValue);
    const sentiment: FeedbackSentiment = isCurrentValue ? 'positive' : 'negative';

    feedbackService.recordFeedback({
      type: 'choice',
      userId: ctx.user.userId,
      adaptationId,
      adaptationType,
      setting,
      adaptedValue,
      sentiment,
      preferredValue: option.value,
      context: {
        deviceType: ctx.device.type,
        screenWidth: ctx.device.screenWidth,
        taskMode: ctx.task.mode,
        confidence: ctx.confidence,
      },
    });

    setSelectedId(option.id);
    setSubmitted(true);
    onFeedback?.(sentiment);
  }, [adaptationId, adaptationType, setting, adaptedValue, onFeedback]);

  if (submitted) {
    const selected = options.find(o => o.id === selectedId);
    return (
      <div
        className={`feedback-widget choice ${variant} ${size} submitted`}
        role="status"
        aria-live="polite"
      >
        <span className="feedback-thanks">
          ✓ Preference saved: {selected?.label}
        </span>
      </div>
    );
  }

  return (
    <div
      className={`feedback-widget choice ${variant} ${size}`}
      role="group"
      aria-label="Choice feedback"
    >
      <span className="feedback-question">{question}</span>

      <div className="choice-options" role="radiogroup">
        {options.map(option => (
          <button
            key={option.id}
            className={`choice-option ${
              JSON.stringify(option.value) === JSON.stringify(adaptedValue) ? 'current' : ''
            }`}
            onClick={() => handleChoice(option)}
            role="radio"
            aria-checked={false}
          >
            {option.label}
            {JSON.stringify(option.value) === JSON.stringify(adaptedValue) && (
              <span className="current-badge">(current)</span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}

