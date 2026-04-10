export type AppMode = 'chat' | 'cowork' | 'training';

export interface ContextPill {
  label: string;
  icon: string;
  action?: 'navigate' | 'activate';
  target?: string;
}
