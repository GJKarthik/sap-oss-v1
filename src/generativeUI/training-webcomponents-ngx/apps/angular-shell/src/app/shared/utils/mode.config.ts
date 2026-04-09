import type { AppMode, ModeConfig, ContextPill } from './mode.types';

export const MODE_CONFIG: Record<AppMode, ModeConfig> = {
  chat: {
    label: 'Chat',
    icon: 'discussion-2',
    confirmationLevel: 'conversational',
    suggestedRoutes: ['/dashboard', '/chat', '/semantic-search'],
    systemPromptPrefix:
      'You are a conversational assistant. Answer questions, explain concepts, and suggest next steps. Do not execute actions autonomously.',
  },
  cowork: {
    label: 'Cowork',
    icon: 'collaborate',
    confirmationLevel: 'per-action',
    suggestedRoutes: ['/rag-studio', '/analytical-dashboard', '/pal-workbench', '/sparql-explorer'],
    systemPromptPrefix:
      'Plan before acting. Present structured proposals with clear steps. Wait for user approval before executing each action.',
  },
  training: {
    label: 'Training',
    icon: 'accelerated',
    confirmationLevel: 'autonomous',
    suggestedRoutes: [
      '/pipeline', '/data-explorer', '/model-optimizer', '/deployments',
      '/vocab-search', '/data-cleaning', '/glossary-manager', '/pair-studio',
    ],
    systemPromptPrefix:
      'Execute autonomously. Run pipelines, training jobs, and data operations. Report progress and results.',
  },
};

export const MODE_PILLS: Record<AppMode, ContextPill[]> = {
  chat: [
    { label: 'Recent chats', icon: 'history', action: 'navigate', target: '/chat' },
    { label: 'Help', icon: 'sys-help', action: 'navigate', target: '/chat?help=true' },
  ],
  cowork: [
    { label: 'Pending plans', icon: 'task', action: 'show-pending' },
    { label: 'Preview', icon: 'inspect', action: 'show-preview' },
  ],
  training: [
    { label: 'Active jobs', icon: 'process', action: 'navigate', target: '/pipeline' },
    { label: 'GPU status', icon: 'machine', action: 'show-gpu' },
  ],
};
