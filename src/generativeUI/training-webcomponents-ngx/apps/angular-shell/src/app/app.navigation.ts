/**
 * SAP AI Workbench navigation model.
 *
 * Defines route links, nav groups, expert routes, and group resolution.
 */

import type { AppMode } from './shared/utils/mode.types';

export type TrainingRouteGroupId = 'home' | 'data' | 'assist' | 'operations';

export interface TrainingRouteLink {
  path: string;
  labelKey: string;
  icon: string;
  group: TrainingRouteGroupId;
  tier: 'primary' | 'secondary' | 'expert';
  modeRelevance: AppMode[];
}

export interface TrainingNavGroup {
  id: TrainingRouteGroupId;
  labelKey: string;
  defaultPath: string;
}

export const TRAINING_ROUTE_LINKS: TrainingRouteLink[] = [
  // -- Hub 1: Home --
  { path: '/dashboard', labelKey: 'nav.dashboard', icon: 'home', group: 'home', tier: 'primary', modeRelevance: ['chat', 'cowork', 'training'] },

  // -- Hub 2: Data Work --
  { path: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder', group: 'data', tier: 'primary', modeRelevance: ['training'] },
  { path: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit', group: 'data', tier: 'primary', modeRelevance: ['training'] },
  { path: '/schema-browser', labelKey: 'nav.schemaBrowser', icon: 'table-view', group: 'data', tier: 'primary', modeRelevance: ['cowork', 'training'] },
  { path: '/data-products', labelKey: 'nav.dataProducts', icon: 'product', group: 'data', tier: 'primary', modeRelevance: ['training'] },
  { path: '/data-quality', labelKey: 'nav.dataQuality', icon: 'validate', group: 'data', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/lineage', labelKey: 'nav.lineage', icon: 'org-chart', group: 'data', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/vocab-search', labelKey: 'nav.vocabSearch', icon: 'grid', group: 'data', tier: 'expert', modeRelevance: ['training'] },

  // -- Hub 3: AI Assistance --
  { path: '/chat', labelKey: 'nav.chat', icon: 'discussion-2', group: 'assist', tier: 'primary', modeRelevance: ['chat'] },
  { path: '/rag-studio', labelKey: 'nav.ragStudio', icon: 'database', group: 'assist', tier: 'primary', modeRelevance: ['cowork'] },
  { path: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search', group: 'assist', tier: 'primary', modeRelevance: ['chat'] },
  { path: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document', group: 'assist', tier: 'secondary', modeRelevance: ['chat', 'cowork'] },
  { path: '/pal-workbench', labelKey: 'nav.palWorkbench', icon: 'action', group: 'assist', tier: 'secondary', modeRelevance: ['cowork'] },
  { path: '/sparql-explorer', labelKey: 'nav.sparqlExplorer', icon: 'syntax', group: 'assist', tier: 'expert', modeRelevance: ['cowork'] },
  { path: '/analytical-dashboard', labelKey: 'nav.analyticalDashboard', icon: 'chart-table-view', group: 'assist', tier: 'expert', modeRelevance: ['cowork'] },
  { path: '/streaming', labelKey: 'nav.streaming', icon: 'monitor-payments', group: 'assist', tier: 'expert', modeRelevance: ['chat', 'cowork', 'training'] },

  // -- Hub 4: Run and Optimize --
  { path: '/pipeline', labelKey: 'nav.pipeline', icon: 'process', group: 'operations', tier: 'primary', modeRelevance: ['training'] },
  { path: '/deployments', labelKey: 'nav.deployments', icon: 'shipping-status', group: 'operations', tier: 'primary', modeRelevance: ['training'] },
  { path: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine', group: 'operations', tier: 'primary', modeRelevance: ['training'] },
  { path: '/registry', labelKey: 'nav.registry', icon: 'tags', group: 'operations', tier: 'secondary', modeRelevance: ['training'] },
  { path: '/hana-explorer', labelKey: 'nav.hanaExplorer', icon: 'database', group: 'operations', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/compare', labelKey: 'nav.compare', icon: 'compare', group: 'operations', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/governance', labelKey: 'nav.governance', icon: 'shield', group: 'operations', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/analytics', labelKey: 'nav.analytics', icon: 'lead', group: 'operations', tier: 'secondary', modeRelevance: ['cowork', 'training'] },
  { path: '/pair-studio', labelKey: 'nav.pairStudio', icon: 'translate', group: 'operations', tier: 'primary', modeRelevance: ['training'] },
  { path: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items', group: 'operations', tier: 'expert', modeRelevance: ['training'] },
  { path: '/document-linguist', labelKey: 'nav.documentLinguist', icon: 'learning-assistant', group: 'operations', tier: 'expert', modeRelevance: ['cowork', 'training'] },
  { path: '/prompts', labelKey: 'nav.promptLibrary', icon: 'document-text', group: 'operations', tier: 'secondary', modeRelevance: ['chat', 'cowork', 'training'] },
  { path: '/workspace', labelKey: 'nav.workspace', icon: 'action-settings', group: 'operations', tier: 'secondary', modeRelevance: ['chat', 'cowork', 'training'] },
];

export const TRAINING_NAV_GROUPS: TrainingNavGroup[] = [
  { id: 'home', labelKey: 'navGroup.home', defaultPath: '/dashboard' },
  { id: 'data', labelKey: 'navGroup.data', defaultPath: '/data-explorer' },
  { id: 'assist', labelKey: 'navGroup.assist', defaultPath: '/chat' },
  { id: 'operations', labelKey: 'navGroup.operations', defaultPath: '/pipeline' },
];

/** Expert-only routes for advanced users (subset of route links with tier=expert) */
export const TRAINING_EXPERT_ROUTES: TrainingRouteLink[] = TRAINING_ROUTE_LINKS.filter(
  (link) => link.tier === 'expert',
);

/** Resolve the active nav group from a URL path */
export function resolveTrainingGroup(path: string): TrainingRouteGroupId {
  const currentPath = path.split('?')[0].split('#')[0] || '/dashboard';
  const match = TRAINING_ROUTE_LINKS.find(
    (link) => currentPath === link.path || currentPath.startsWith(`${link.path}/`),
  );
  return match?.group ?? 'home';
}
