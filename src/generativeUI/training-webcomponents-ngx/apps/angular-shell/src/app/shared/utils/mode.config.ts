import { AppMode, ModeConfig, ModePill } from './mode.types';

export const MODE_CONFIG: Record<AppMode, ModeConfig> = {
  chat: {
    id: 'chat',
    labelKey: 'mode.chat',
    icon: 'discussion-2',
    descriptionKey: 'mode.chatDesc',
    systemPromptPrefix: 'You are a helpful SAP AI assistant. Answer questions, explain concepts, and guide the user.',
    confirmationLevel: 'always',
    groupRelevance: {
      assist: 1.0,
      data: 0.6,
      content: 0.5,
      mlops: 0.4,
    },
  },
  cowork: {
    id: 'cowork',
    labelKey: 'mode.cowork',
    icon: 'collaborate',
    descriptionKey: 'mode.coworkDesc',
    systemPromptPrefix: 'You are a collaborative AI partner. Propose actionable plans, await approval before executing. Show your reasoning.',
    confirmationLevel: 'destructive-only',
    groupRelevance: {
      assist: 0.8,
      data: 1.0,
      mlops: 1.0,
      content: 0.8,
    },
  },
  training: {
    id: 'training',
    labelKey: 'mode.training',
    icon: 'process',
    descriptionKey: 'mode.trainingDesc',
    systemPromptPrefix: 'You are an autonomous pipeline executor. Run tasks end-to-end, report results. Minimize interruptions.',
    confirmationLevel: 'never',
    groupRelevance: {
      assist: 0.6,
      data: 0.8,
      mlops: 1.0,
      content: 0.7,
    },
  },
};

export const ALL_MODES: AppMode[] = ['chat', 'cowork', 'training'];

export const MODE_PILLS: ModePill[] = [
  { labelKey: 'pill.askQuestion', icon: 'question-mark', action: 'ask', modes: ['chat'] },
  { labelKey: 'pill.explainThis', icon: 'hint', action: 'explain', modes: ['chat'] },
  { labelKey: 'pill.proposePlan', icon: 'task', action: 'propose', modes: ['cowork'] },
  { labelKey: 'pill.reviewChanges', icon: 'compare', action: 'review', modes: ['cowork'] },
  { labelKey: 'pill.runPipeline', icon: 'process', action: 'run', modes: ['training'] },
  { labelKey: 'pill.showMetrics', icon: 'chart-table-view', action: 'metrics', modes: ['training'] },
  { labelKey: 'pill.debugIssue', icon: 'wrench', action: 'debug', modes: ['cowork', 'training'] },
];

export const DEFAULT_MODE: AppMode = 'chat';
export const MODE_STORAGE_KEY = 'sap-ai-mode';
