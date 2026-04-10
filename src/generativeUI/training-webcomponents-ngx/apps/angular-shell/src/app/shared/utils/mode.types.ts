export type AppMode = 'chat' | 'cowork' | 'training';

export type CoworkPlanStepStatus = 'pending' | 'running' | 'completed' | 'failed';

export interface CoworkPlanStep {
  label: string;
  description: string;
  status: CoworkPlanStepStatus;
}

export type CoworkPlanStatus = 'proposed' | 'executing' | 'completed' | 'rejected';

export interface CoworkPlan {
  id: string;
  steps: CoworkPlanStep[];
  status: CoworkPlanStatus;
}

export interface ContextPill {
  label: string;
  icon: string;
  action?: 'navigate' | 'activate';
  target?: string;
}
