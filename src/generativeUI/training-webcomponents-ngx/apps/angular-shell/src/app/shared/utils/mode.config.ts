import type { AppMode } from './mode.types';

export interface ModeDefinition {
  label: string;
  icon: string;
}

export const MODE_CONFIG: Record<AppMode, ModeDefinition> = {
  chat: { label: 'Chat', icon: 'conversation' },
  cowork: { label: 'Co-work', icon: 'collaborate' },
  training: { label: 'Training', icon: 'process' },
};
