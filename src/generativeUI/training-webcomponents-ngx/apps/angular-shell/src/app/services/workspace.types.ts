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
  defaultLandingPath: string;
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

export interface TrainingNavLink {
  route: string;
  labelKey: string;
  icon: string;
}

export const TRAINING_NAV_LINKS: TrainingNavLink[] = [
  { route: '/dashboard', labelKey: 'nav.dashboard', icon: 'home' },
  { route: '/pipeline', labelKey: 'nav.pipeline', icon: 'process' },
  { route: '/data-explorer', labelKey: 'nav.dataExplorer', icon: 'folder' },
  { route: '/data-cleaning', labelKey: 'nav.dataCleaning', icon: 'edit' },
  { route: '/model-optimizer', labelKey: 'nav.modelOptimizer', icon: 'machine' },
  { route: '/registry', labelKey: 'nav.registry', icon: 'tags' },
  { route: '/hippocpp', labelKey: 'nav.hippocpp', icon: 'chain-link' },
  { route: '/chat', labelKey: 'nav.chat', icon: 'discussion-2' },
  { route: '/compare', labelKey: 'nav.compare', icon: 'compare' },
  { route: '/document-ocr', labelKey: 'nav.documentOcr', icon: 'document' },
  { route: '/semantic-search', labelKey: 'nav.semanticSearch', icon: 'search' },
  { route: '/analytics', labelKey: 'nav.analytics', icon: 'lead' },
  { route: '/glossary-manager', labelKey: 'nav.glossaryManager', icon: 'activity-items' },
  { route: '/arabic-wizard', labelKey: 'nav.arabicWizard', icon: 'learning-assistant' },
  { route: '/governance', labelKey: 'nav.governance', icon: 'shield' },
  { route: '/prompt-library', labelKey: 'nav.promptLibrary', icon: 'document-text' },
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
      defaultLandingPath: '/dashboard',
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
    theme: 'sap_horizon',
    language: 'en',
    updatedAt: new Date().toISOString(),
  };
}
