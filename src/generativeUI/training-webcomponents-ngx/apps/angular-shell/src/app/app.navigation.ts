/**
 * Training Console — Navigation model
 *
 * Defines route links, nav groups, expert routes, and group resolution.
 */

export type TrainingRouteGroupId = 'overview' | 'pipeline' | 'data' | 'models' | 'assistants' | 'expert';

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
  { path: '/dashboard', labelKey: 'nav.dashboard', icon: 'home', group: 'overview', tier: 'primary' },
  { path: '/pipeline', labelKey: 'nav.pipeline', icon: 'process', group: 'pipeline', tier: 'primary' },
  { path: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder', group: 'data', tier: 'primary' },
  { path: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit', group: 'data', tier: 'secondary' },
  { path: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine', group: 'models', tier: 'primary' },
  { path: '/registry', labelKey: 'nav.registry', icon: 'tags', group: 'models', tier: 'secondary' },
  { path: '/chat', labelKey: 'nav.chat', icon: 'discussion-2', group: 'assistants', tier: 'primary' },
  { path: '/compare', labelKey: 'nav.compare', icon: 'compare', group: 'assistants', tier: 'secondary' },
  { path: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items', group: 'assistants', tier: 'secondary' },
  { path: '/arabic-wizard', labelKey: 'nav.arabicWizard', icon: 'learning-assistant', group: 'assistants', tier: 'secondary' },
  { path: '/hippocpp', labelKey: 'nav.hippocpp', icon: 'chain-link', group: 'expert', tier: 'expert' },
  { path: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document', group: 'expert', tier: 'expert' },
  { path: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search', group: 'expert', tier: 'expert' },
  { path: '/analytics', labelKey: 'nav.analytics', icon: 'lead', group: 'expert', tier: 'expert' },
];

export const TRAINING_NAV_GROUPS: TrainingNavGroup[] = [
  { id: 'overview', labelKey: 'navGroup.overview', defaultPath: '/dashboard' },
  { id: 'pipeline', labelKey: 'navGroup.pipeline', defaultPath: '/pipeline' },
  { id: 'data', labelKey: 'navGroup.data', defaultPath: '/data-explorer' },
  { id: 'models', labelKey: 'navGroup.models', defaultPath: '/model-optimizer' },
  { id: 'assistants', labelKey: 'navGroup.assistants', defaultPath: '/chat' },
  { id: 'expert', labelKey: 'navGroup.expert', defaultPath: '/hippocpp' },
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
  return match?.group ?? 'overview';
}
