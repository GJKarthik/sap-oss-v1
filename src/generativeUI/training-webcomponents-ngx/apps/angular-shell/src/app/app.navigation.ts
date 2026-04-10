/**
 * SAP AI Workbench navigation model.
 *
 * Defines route links, nav groups, expert routes, and group resolution.
 * Each route has optional modeRelevance overrides for the three-mode switcher.
 */

import { ModeRelevance } from './shared/utils/mode.types';

export type TrainingRouteGroupId = 'home' | 'data' | 'assist' | 'operations';

export interface TrainingRouteLink {
  path: string;
  labelKey: string;
  icon: string;
  group: TrainingRouteGroupId;
  tier: 'primary' | 'secondary' | 'expert';
  /** Per-route mode relevance overrides (falls back to group relevance if absent) */
  modeRelevance?: ModeRelevance;
}

export interface TrainingNavGroup {
  id: TrainingRouteGroupId;
  labelKey: string;
  defaultPath: string;
}

export const TRAINING_ROUTE_LINKS: TrainingRouteLink[] = [
  // -- Hub 1: Home --
  { path: '/dashboard', labelKey: 'nav.dashboard', icon: 'home', group: 'home', tier: 'primary' },

  // -- Hub 2: Data Work --
  { path: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder', group: 'data', tier: 'primary' },
  { path: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit', group: 'data', tier: 'primary', modeRelevance: { cowork: 1.0, training: 0.9 } },
  { path: '/schema-browser', labelKey: 'nav.schemaBrowser', icon: 'table-view', group: 'data', tier: 'primary' },
  { path: '/data-products', labelKey: 'nav.dataProducts', icon: 'product', group: 'data', tier: 'primary', modeRelevance: { cowork: 1.0, training: 1.0 } },
  { path: '/data-quality', labelKey: 'nav.dataQuality', icon: 'validate', group: 'data', tier: 'secondary', modeRelevance: { training: 1.0 } },
  { path: '/lineage', labelKey: 'nav.lineage', icon: 'org-chart', group: 'data', tier: 'secondary' },
  { path: '/vocab-search', labelKey: 'nav.vocabSearch', icon: 'grid', group: 'data', tier: 'expert' },

  // -- Hub 3: AI Assistance --
  { path: '/chat', labelKey: 'nav.chat', icon: 'discussion-2', group: 'assist', tier: 'primary', modeRelevance: { chat: 1.0, cowork: 0.9, training: 0.5 } },
  { path: '/rag-studio', labelKey: 'nav.ragStudio', icon: 'database', group: 'assist', tier: 'primary', modeRelevance: { cowork: 1.0, training: 0.8 } },
  { path: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search', group: 'assist', tier: 'primary', modeRelevance: { chat: 1.0 } },
  { path: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document', group: 'assist', tier: 'secondary' },
  { path: '/pal-workbench', labelKey: 'nav.palWorkbench', icon: 'action', group: 'assist', tier: 'secondary', modeRelevance: { cowork: 0.9, training: 1.0 } },
  { path: '/sparql-explorer', labelKey: 'nav.sparqlExplorer', icon: 'syntax', group: 'assist', tier: 'expert' },
  { path: '/analytical-dashboard', labelKey: 'nav.analyticalDashboard', icon: 'chart-table-view', group: 'assist', tier: 'expert', modeRelevance: { training: 0.9 } },
  { path: '/streaming', labelKey: 'nav.streaming', icon: 'monitor-payments', group: 'assist', tier: 'expert', modeRelevance: { training: 1.0 } },

  // -- Hub 4: Run and Optimize --
  { path: '/pipeline', labelKey: 'nav.pipeline', icon: 'process', group: 'operations', tier: 'primary', modeRelevance: { training: 1.0, cowork: 0.9 } },
  { path: '/deployments', labelKey: 'nav.deployments', icon: 'shipping-status', group: 'operations', tier: 'primary', modeRelevance: { training: 1.0 } },
  { path: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine', group: 'operations', tier: 'primary', modeRelevance: { training: 1.0, cowork: 1.0 } },
  { path: '/registry', labelKey: 'nav.registry', icon: 'tags', group: 'operations', tier: 'secondary' },
  { path: '/hana-explorer', labelKey: 'nav.hanaExplorer', icon: 'database', group: 'operations', tier: 'secondary' },
  { path: '/compare', labelKey: 'nav.compare', icon: 'compare', group: 'operations', tier: 'secondary', modeRelevance: { cowork: 1.0 } },
  { path: '/governance', labelKey: 'nav.governance', icon: 'shield', group: 'operations', tier: 'secondary' },
  { path: '/analytics', labelKey: 'nav.analytics', icon: 'lead', group: 'operations', tier: 'secondary', modeRelevance: { training: 0.9 } },
  { path: '/pair-studio', labelKey: 'nav.pairStudio', icon: 'translate', group: 'operations', tier: 'primary', modeRelevance: { training: 1.0 } },
  { path: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items', group: 'operations', tier: 'expert' },
  { path: '/arabic-wizard', labelKey: 'nav.arabicWizard', icon: 'learning-assistant', group: 'operations', tier: 'expert' },
  { path: '/prompts', labelKey: 'nav.promptLibrary', icon: 'document-text', group: 'operations', tier: 'secondary', modeRelevance: { chat: 1.0, cowork: 0.8 } },
  { path: '/workspace', labelKey: 'nav.workspace', icon: 'action-settings', group: 'operations', tier: 'secondary' },
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
