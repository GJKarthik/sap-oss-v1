import { environment } from '../../environments/environment';

export interface WorkspaceIdentity {
  userId: string;
  displayName: string;
  teamName: string;
}

export interface WorkspaceBackendConfig {
  apiBaseUrl: string;
  collabWsUrl: string;
}

export interface WorkspaceNavItem {
  route: string;
  visible: boolean;
  order: number;
}

export interface WorkspaceNavConfig {
  items: WorkspaceNavItem[];
}

export interface WorkspaceModelPrefs {
  defaultModel: string;
  temperature: number;
  systemPrompt: string;
}

export interface WorkspaceSettings {
  version: 1;
  identity: WorkspaceIdentity;
  backend: WorkspaceBackendConfig;
  nav: WorkspaceNavConfig;
  model: WorkspaceModelPrefs;
  theme: string;
  language: string;
  updatedAt: string;
}

export const PRODUCT_THEMES = ['sap_horizon', 'sap_horizon_dark'] as const;
export type ProductTheme = (typeof PRODUCT_THEMES)[number];

export function normalizeWorkspaceTheme(theme: string | null | undefined): ProductTheme {
  switch (theme) {
    case 'sap_horizon_dark':
    case 'sap_fiori_3_dark':
      return 'sap_horizon_dark';
    case 'sap_horizon':
    case 'sap_fiori_3':
    default:
      return 'sap_horizon';
  }
}

export interface TrainingNavLink {
  route: string;
  labelKey: string;
  icon: string;
}

export const TRAINING_NAV_LINKS: TrainingNavLink[] = [
  // Home
  { route: '/dashboard', labelKey: 'nav.dashboard', icon: 'home' },
  // Data Work
  { route: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder' },
  { route: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit' },
  { route: '/schema-browser', labelKey: 'nav.schemaBrowser', icon: 'table-view' },
  { route: '/data-products', labelKey: 'nav.dataProducts', icon: 'product' },
  { route: '/data-quality', labelKey: 'nav.dataQuality', icon: 'validate' },
  { route: '/lineage', labelKey: 'nav.lineage', icon: 'org-chart' },
  { route: '/vocab-search', labelKey: 'nav.vocabSearch', icon: 'grid' },
  // AI Assistance
  { route: '/chat', labelKey: 'nav.chat', icon: 'discussion-2' },
  { route: '/rag-studio', labelKey: 'nav.ragStudio', icon: 'database' },
  { route: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search' },
  { route: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document' },
  { route: '/pal-workbench', labelKey: 'nav.palWorkbench', icon: 'action' },
  { route: '/sparql-explorer', labelKey: 'nav.sparqlExplorer', icon: 'syntax' },
  { route: '/analytical-dashboard', labelKey: 'nav.analyticalDashboard', icon: 'chart-table-view' },
  { route: '/streaming', labelKey: 'nav.streaming', icon: 'monitor-payments' },
  // Operations
  { route: '/pipeline', labelKey: 'nav.pipeline', icon: 'process' },
  { route: '/deployments', labelKey: 'nav.deployments', icon: 'shipping-status' },
  { route: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine' },
  { route: '/registry', labelKey: 'nav.registry', icon: 'tags' },
  { route: '/hana-explorer', labelKey: 'nav.hanaExplorer', icon: 'database' },
  { route: '/compare', labelKey: 'nav.compare', icon: 'compare' },
  { route: '/governance', labelKey: 'nav.governance', icon: 'shield' },
  { route: '/analytics', labelKey: 'nav.analytics', icon: 'lead' },
  { route: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items' },
  { route: '/document-linguist', labelKey: 'nav.documentLinguist', icon: 'learning-assistant' },
  { route: '/prompts', labelKey: 'nav.promptLibrary', icon: 'document-text' },
  { route: '/workspace', labelKey: 'nav.workspace', icon: 'action-settings' },
];

function generateUserId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return 'tc-user-' + crypto.randomUUID().slice(0, 4).toLowerCase();
  }
  return 'tc-user-' + Date.now().toString(36).slice(-4);
}

export function createDefaultWorkspaceSettings(): WorkspaceSettings {
  const storedUserId = typeof localStorage !== 'undefined'
    ? localStorage.getItem('training.workspace.userId')
    : null;
  const userId = storedUserId || generateUserId();
  if (!storedUserId && typeof localStorage !== 'undefined') {
    localStorage.setItem('training.workspace.userId', userId);
  }

  return {
    version: 1,
    identity: {
      userId,
      displayName: environment.collabDisplayName || 'Training User',
      teamName: '',
    },
    backend: {
      apiBaseUrl: environment.apiBaseUrl,
      collabWsUrl: environment.collabWsUrl,
    },
    nav: {
      items: TRAINING_NAV_LINKS.map((link, i) => ({
        route: link.route,
        visible: true,
        order: i,
      })),
    },
    model: {
      defaultModel: '',
      temperature: 0.7,
      systemPrompt: '',
    },
    theme: normalizeWorkspaceTheme('sap_horizon'),
    language: 'en',
    updatedAt: new Date().toISOString(),
  };
}
