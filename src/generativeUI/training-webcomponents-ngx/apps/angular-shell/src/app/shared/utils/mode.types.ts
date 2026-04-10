export type AppMode = 'chat' | 'cowork' | 'training';
export type ConfirmationLevel = 'conversational' | 'per-action' | 'autonomous';

export interface ModeConfig {
  label: string;
  icon: string;
  confirmationLevel: ConfirmationLevel;
  suggestedRoutes: string[];
  systemPromptPrefix: string;
}

export interface AiCapabilities {
  systemPromptPrefix: string;
  confirmationLevel: ConfirmationLevel;
}

export interface RouteRelevance {
  suggested: string[];
  all: string[];
}

export interface ContextPill {
  label: string;
  icon: string;
  action: string;
  target?: string;
}

export interface CoworkPlan {
  id: string;
  steps: CoworkPlanStep[];
  status: 'proposed' | 'approved' | 'executing' | 'completed' | 'rejected';
}

export interface CoworkPlanStep {
  label: string;
  description: string;
  status: 'pending' | 'running' | 'completed' | 'failed';
}
