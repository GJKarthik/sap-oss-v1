/**
 * Three-Mode Switcher — Type definitions
 *
 * Chat:     Conversational exploration. AI answers questions, explains.
 * Cowork:   Collaborative execution. AI proposes plans, user approves.
 * Training: Autonomous pipeline execution. AI runs with minimal interrupts.
 */

export type AppMode = 'chat' | 'cowork' | 'training';

export interface ModeConfig {
  id: AppMode;
  labelKey: string;
  icon: string;
  descriptionKey: string;
  /** System prompt prefix injected before user messages */
  systemPromptPrefix: string;
  /** Whether AI should ask for confirmation before acting */
  confirmationLevel: 'always' | 'destructive-only' | 'never';
  /** Nav group relevance: groups scored 1.0 (primary) to 0.3 (dimmed) */
  groupRelevance: Record<string, number>;
}

export interface ModePill {
  labelKey: string;
  icon: string;
  action: string;
  /** Which mode(s) this pill appears in */
  modes: AppMode[];
}

export type ModeRelevance = Partial<Record<AppMode, number>>;
