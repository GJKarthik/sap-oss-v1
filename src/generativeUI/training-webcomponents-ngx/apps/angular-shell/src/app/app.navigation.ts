/**
 * Training Console — Navigation model
 *
 * Defines route links, nav groups, expert routes, and group resolution.
 */

export type TrainingRouteGroupId = 'home' | 'data-factory' | 'ai-lab' | 'mlops';

export interface TrainingRouteLink {
  path: string;
  labelKey: string;
  icon: string;
  group: TrainingRouteGroupId;
  tier: 'primary' | 'secondary' | 'expert';
}

export interface TrainingNavGroup {
  id: TrainingRouteGroupId;
  labelKey: string;
  defaultPath: string;
}

export const TRAINING_ROUTE_LINKS: TrainingRouteLink[] = [
  // -- Hub 1: Home --
  { path: '/dashboard', labelKey: 'nav.dashboard', icon: 'home', group: 'home', tier: 'primary' },

  // -- Hub 2: Data Factory --
  { path: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder', group: 'data-factory', tier: 'primary' },
  { path: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit', group: 'data-factory', tier: 'primary' },
  { path: '/schema-browser', labelKey: 'nav.schemaBrowser', icon: 'table-view', group: 'data-factory', tier: 'primary' },
  { path: '/data-quality', labelKey: 'nav.dataQuality', icon: 'validate', group: 'data-factory', tier: 'secondary' },
  { path: '/lineage', labelKey: 'nav.lineage', icon: 'org-chart', group: 'data-factory', tier: 'secondary' },
  { path: '/vocab-search', labelKey: 'nav.vocabSearch', icon: 'grid', group: 'data-factory', tier: 'expert' },

  // -- Hub 3: AI Lab --
  { path: '/chat', labelKey: 'nav.chat', icon: 'discussion-2', group: 'ai-lab', tier: 'primary' },
  { path: '/rag-studio', labelKey: 'nav.ragStudio', icon: 'database', group: 'ai-lab', tier: 'primary' },
  { path: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search', group: 'ai-lab', tier: 'primary' },
  { path: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document', group: 'ai-lab', tier: 'secondary' },
  { path: '/playground', labelKey: 'nav.playground', icon: 'lab', group: 'ai-lab', tier: 'secondary' },
  { path: '/sparql-explorer', labelKey: 'nav.sparqlExplorer', icon: 'syntax', group: 'ai-lab', tier: 'expert' },
  { path: '/analytical-dashboard', labelKey: 'nav.analyticalDashboard', icon: 'chart-table-view', group: 'ai-lab', tier: 'expert' },
  { path: '/streaming', labelKey: 'nav.streaming', icon: 'monitor-payments', group: 'ai-lab', tier: 'expert' },

  // -- Hub 4: MLOps Studio --
  { path: '/pipeline', labelKey: 'nav.pipeline', icon: 'process', group: 'mlops', tier: 'primary' },
  { path: '/deployments', labelKey: 'nav.deployments', icon: 'shipping-status', group: 'mlops', tier: 'primary' },
  { path: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine', group: 'mlops', tier: 'primary' },
  { path: '/registry', labelKey: 'nav.registry', icon: 'tags', group: 'mlops', tier: 'secondary' },
  { path: '/hippocpp', labelKey: 'nav.hippocpp', icon: 'chain-link', group: 'mlops', tier: 'secondary' },
  { path: '/compare', labelKey: 'nav.compare', icon: 'compare', group: 'mlops', tier: 'secondary' },
  { path: '/governance', labelKey: 'nav.governance', icon: 'shield', group: 'mlops', tier: 'secondary' },
  { path: '/analytics', labelKey: 'nav.analytics', icon: 'lead', group: 'mlops', tier: 'secondary' },
  { path: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items', group: 'mlops', tier: 'expert' },
  { path: '/arabic-wizard', labelKey: 'nav.arabicWizard', icon: 'learning-assistant', group: 'mlops', tier: 'expert' },
  { path: '/prompts', labelKey: 'nav.promptLibrary', icon: 'document-text', group: 'mlops', tier: 'secondary' },
  { path: '/workspace', labelKey: 'nav.workspace', icon: 'action-settings', group: 'mlops', tier: 'secondary' },
];

export const TRAINING_NAV_GROUPS: TrainingNavGroup[] = [
  { id: 'home', labelKey: 'navGroup.home', defaultPath: '/dashboard' },
  { id: 'data-factory', labelKey: 'navGroup.data', defaultPath: '/data-explorer' },
  { id: 'ai-lab', labelKey: 'navGroup.assistants', defaultPath: '/chat' },
  { id: 'mlops', labelKey: 'navGroup.operations', defaultPath: '/pipeline' },
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
