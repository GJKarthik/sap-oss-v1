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
  { path: '/overview', labelKey: 'nav.overview', icon: 'home', group: 'home', tier: 'primary' },

  // -- Hub 2: Data Factory (Production-grade Data Orchestration) --
  { path: '/assets', labelKey: 'nav.assets', icon: 'folder', group: 'data-factory', tier: 'primary' },
  { path: '/schema', labelKey: 'nav.schema', icon: 'table-view', group: 'data-factory', tier: 'primary' },
  { path: '/quality', labelKey: 'nav.quality', icon: 'validate', group: 'data-factory', tier: 'secondary' },
  { path: '/prep', labelKey: 'nav.prep', icon: 'edit', group: 'data-factory', tier: 'secondary' },
  { path: '/lineage', labelKey: 'nav.lineage', icon: 'org-chart', group: 'data-factory', tier: 'secondary' },

  // -- Hub 3: AI Lab (Production Inference & Intelligence) --
  { path: '/assistant', labelKey: 'nav.assistant', icon: 'discussion-2', group: 'ai-lab', tier: 'primary' },
  { path: '/knowledge', labelKey: 'nav.knowledge', icon: 'database', group: 'ai-lab', tier: 'primary' },
  { path: '/search', labelKey: 'nav.search', icon: 'search', group: 'ai-lab', tier: 'secondary' },
  { path: '/documents', labelKey: 'nav.documents', icon: 'learning-assistant', group: 'ai-lab', tier: 'secondary' },

  // -- Hub 4: MLOps Studio (System Orchestration) --
  { path: '/pipeline', labelKey: 'nav.pipeline', icon: 'process', group: 'mlops', tier: 'primary' },
  { path: '/deployments', labelKey: 'nav.deployments', icon: 'shipping-status', group: 'mlops', tier: 'primary' },
  { path: '/training', labelKey: 'nav.training', icon: 'machine', group: 'mlops', tier: 'secondary' },
  { path: '/models', labelKey: 'nav.models', icon: 'tags', group: 'mlops', tier: 'secondary' },
  { path: '/governance', labelKey: 'nav.governance', icon: 'shield', group: 'mlops', tier: 'secondary' },
];

export const TRAINING_NAV_GROUPS: TrainingNavGroup[] = [
  { id: 'home', labelKey: 'navGroup.home', defaultPath: '/overview' },
  { id: 'data-factory', labelKey: 'navGroup.data', defaultPath: '/assets' },
  { id: 'ai-lab', labelKey: 'navGroup.assistants', defaultPath: '/assistant' },
  { id: 'mlops', labelKey: 'navGroup.operations', defaultPath: '/pipeline' },
];

/** Expert-only routes for advanced users (subset of route links with tier=expert) */
export const TRAINING_EXPERT_ROUTES: TrainingRouteLink[] = TRAINING_ROUTE_LINKS.filter(
  (link) => link.tier === 'expert',
);

/** Resolve the active nav group from a URL path */
export function resolveTrainingGroup(path: string): TrainingRouteGroupId {
  const currentPath = path.split('?')[0].split('#')[0] || '/overview';
  const match = TRAINING_ROUTE_LINKS.find(
    (link) => currentPath === link.path || currentPath.startsWith(`${link.path}/`),
  );
  return match?.group ?? 'home';
}
