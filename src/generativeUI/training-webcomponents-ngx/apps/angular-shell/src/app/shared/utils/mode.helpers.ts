import type { AppMode } from './mode.types';

export interface ModeCapabilities {
  confirmationLevel: 'conversational' | 'per-action' | 'autonomous';
  canRunPipelines: boolean;
  canEditDocuments: boolean;
}

export interface RouteRelevance {
  suggested: string[];
  hidden: string[];
}

export interface ContextPill {
  label: string;
  icon: string;
}

export function getModeCapabilities(mode: AppMode): ModeCapabilities {
  switch (mode) {
    case 'chat':
      return { confirmationLevel: 'conversational', canRunPipelines: false, canEditDocuments: false };
    case 'cowork':
      return { confirmationLevel: 'per-action', canRunPipelines: true, canEditDocuments: true };
    case 'training':
      return { confirmationLevel: 'autonomous', canRunPipelines: true, canEditDocuments: true };
  }
}

export function getRouteRelevance(mode: AppMode): RouteRelevance {
  switch (mode) {
    case 'chat':
      return { suggested: ['/chat', '/hana-explorer'], hidden: ['/pipeline', '/pair-studio'] };
    case 'cowork':
      return { suggested: ['/chat', '/pair-studio', '/hana-explorer'], hidden: [] };
    case 'training':
      return { suggested: ['/pipeline', '/pair-studio', '/deployments'], hidden: ['/chat'] };
  }
}

export function getContextPills(mode: AppMode): ContextPill[] {
  switch (mode) {
    case 'chat':
      return [{ label: 'Chat', icon: 'conversation' }];
    case 'cowork':
      return [{ label: 'Co-work', icon: 'collaborate' }, { label: 'Documents', icon: 'document' }];
    case 'training':
      return [
        { label: 'Pipeline', icon: 'process' },
        { label: 'Pair Studio', icon: 'ai' },
        { label: 'Deployments', icon: 'cloud' },
      ];
  }
}
