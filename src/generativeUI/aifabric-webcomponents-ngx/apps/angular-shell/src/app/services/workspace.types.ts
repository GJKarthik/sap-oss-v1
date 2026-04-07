import { environment } from '../../environments/environment';
import { AI_FABRIC_NAV_ITEMS, AiFabricNavItem } from '../app.navigation';

// ─── Cross-App Workspace (use-case + team scoped) ───────────────────

/** Which app a feature belongs to */
export type AppId = 'aifabric' | 'training' | 'joule';

/** A feature that can be orchestrated from any app */
export interface CrossAppFeature {
  /** Unique feature key, e.g. 'rag-studio', 'arabic-wizard' */
  id: string;
  /** Human label */
  label: string;
  /** Which app owns this feature */
  sourceApp: AppId;
  /** Route within the source app, e.g. '/rag' */
  route: string;
  /** Icon (UI5 icon set) */
  icon: string;
  /** Absolute URL when accessed from a different app */
  crossAppUrl?: string;
}

/** Team member within a workspace */
export interface WorkspaceTeamMember {
  userId: string;
  displayName: string;
  role: 'lead' | 'member' | 'viewer';
}

/** Cross-app use-case workspace */
export interface UseCaseWorkspace {
  /** Workspace ID */
  id: string;
  /** Use case name, e.g. "Trial Balance Automation" */
  useCase: string;
  /** Description of what this workspace is for */
  description: string;
  /** Team that owns the workspace */
  team: {
    teamId: string;
    teamName: string;
    members: WorkspaceTeamMember[];
  };
  /** Features from any app that are relevant to this use case */
  features: CrossAppFeature[];
  /** Use-case-specific configuration */
  useCaseConfig: Record<string, unknown>;
  /** IDs of governance policies scoped to this use case */
  governancePolicyIds: string[];
  /** IDs of prompt templates curated for this use case */
  promptIds: string[];
  /** Collab room derived from workspace ID (all apps join same room) */
  collabRoomId: string;
  /** Default language for this workspace */
  language: string;
  /** Default LLM model for this workspace */
  defaultModel: string;
  createdAt: string;
  updatedAt: string;
}

export interface WorkspaceIdentity {
  userId: string;
  displayName: string;
  teamName: string;
}

export interface WorkspaceBackendConfig {
  apiBaseUrl: string;
  elasticsearchMcpUrl: string;
  palMcpUrl: string;
  collabWsUrl: string;
}

export interface WorkspaceNavItem {
  id: string;
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
  /** Currently active cross-app use-case workspace (null = no workspace selected) */
  activeWorkspaceId: string | null;
}

function generateUserId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return 'af-user-' + crypto.randomUUID().slice(0, 4).toLowerCase();
  }
  return 'af-user-' + Date.now().toString(36).slice(-4);
}

export function createDefaultWorkspaceSettings(): WorkspaceSettings {
  const storedUserId = typeof localStorage !== 'undefined'
    ? localStorage.getItem('aifabric.workspace.userId')
    : null;
  const userId = storedUserId || generateUserId();
  if (!storedUserId && typeof localStorage !== 'undefined') {
    localStorage.setItem('aifabric.workspace.userId', userId);
  }

  return {
    version: 1,
    identity: {
      userId,
      displayName: environment.collabDisplayName || 'AI Fabric User',
      teamName: '',
    },
    backend: {
      apiBaseUrl: environment.apiBaseUrl,
      elasticsearchMcpUrl: environment.elasticsearchMcpUrl,
      palMcpUrl: environment.palMcpUrl,
      collabWsUrl: environment.collabWsUrl,
    },
    nav: {
      defaultLandingPath: '/dashboard',
      items: AI_FABRIC_NAV_ITEMS.map((item, i) => ({
        id: item.id,
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
    activeWorkspaceId: null,
  };
}

// ─── Seed Use-Case Workspaces ───────────────────────────────────────

export const SEED_WORKSPACES: UseCaseWorkspace[] = [
  {
    id: 'ws-trial-balance',
    useCase: 'Trial Balance Automation',
    description: 'Automate trial balance reconciliation with AI-assisted data validation, anomaly detection, and reporting across SAP systems.',
    team: {
      teamId: 'team-finance-ops',
      teamName: 'Finance Operations',
      members: [
        { userId: 'finance-lead', displayName: 'Finance Lead', role: 'lead' },
        { userId: 'analyst-1', displayName: 'Data Analyst', role: 'member' },
        { userId: 'auditor-1', displayName: 'Auditor', role: 'viewer' },
      ],
    },
    features: [
      // aifabric-owned (local in this app)
      { id: 'dashboard', label: 'Dashboard', sourceApp: 'aifabric', route: '/dashboard', icon: 'home' },
      { id: 'data-quality', label: 'Data Quality', sourceApp: 'aifabric', route: '/data-quality', icon: 'validate' },
      { id: 'data-explorer', label: 'Data Explorer', sourceApp: 'aifabric', route: '/data', icon: 'database' },
      { id: 'rag', label: 'Search Studio', sourceApp: 'aifabric', route: '/rag', icon: 'documents' },
      { id: 'lineage', label: 'Lineage', sourceApp: 'aifabric', route: '/lineage', icon: 'org-chart' },
      { id: 'governance', label: 'Governance', sourceApp: 'aifabric', route: '/governance', icon: 'shield' },
      { id: 'prompts', label: 'Prompt Library', sourceApp: 'aifabric', route: '/prompts', icon: 'document-text' },
      // training-owned (cross-app links)
      { id: 'data-cleaning', label: 'Data Cleaning', sourceApp: 'training', route: '/data-cleaning', icon: 'edit', crossAppUrl: '/training/data-cleaning' },
      { id: 'pipeline', label: 'Training Pipeline', sourceApp: 'training', route: '/pipeline', icon: 'process', crossAppUrl: '/training/pipeline' },
      { id: 'analytics', label: 'Analytics', sourceApp: 'training', route: '/analytics', icon: 'business-objects-experience', crossAppUrl: '/training/analytics' },
      // ui5-owned (cross-app links)
      { id: 'joule', label: 'Joule AI', sourceApp: 'joule', route: '/joule', icon: 'da', crossAppUrl: '/joule' },
    ],
    useCaseConfig: { reconciliationThreshold: 0.01, currency: 'USD', fiscalYearEnd: '12-31' },
    governancePolicyIds: ['policy-finance-approval', 'policy-data-export'],
    promptIds: ['seed-1'],
    collabRoomId: 'ws-trial-balance',
    language: 'en',
    defaultModel: 'gpt-4',
    createdAt: '2026-01-15T00:00:00Z',
    updatedAt: '2026-04-01T00:00:00Z',
  },
  {
    id: 'ws-arabic-finance',
    useCase: 'Arabic Finance NLP',
    description: 'Train and deploy Arabic-language NLP models for financial document processing, OCR, and bilingual reporting.',
    team: {
      teamId: 'team-arabic-nlp',
      teamName: 'Arabic NLP Team',
      members: [
        { userId: 'nlp-lead', displayName: 'NLP Lead', role: 'lead' },
        { userId: 'trainer-1', displayName: 'Model Trainer', role: 'member' },
        { userId: 'annotator-1', displayName: 'Data Annotator', role: 'member' },
      ],
    },
    features: [
      // training-owned (cross-app links from aifabric perspective)
      { id: 'arabic-wizard', label: 'Arabic Wizard', sourceApp: 'training', route: '/arabic-wizard', icon: 'learning-assistant', crossAppUrl: '/training/arabic-wizard' },
      { id: 'chat', label: 'Arabic Chat', sourceApp: 'training', route: '/chat', icon: 'discussion-2', crossAppUrl: '/training/chat' },
      { id: 'model-optimizer', label: 'Model Optimizer', sourceApp: 'training', route: '/model-optimizer', icon: 'machine', crossAppUrl: '/training/model-optimizer' },
      { id: 'document-ocr', label: 'Document OCR', sourceApp: 'training', route: '/document-ocr', icon: 'document', crossAppUrl: '/training/document-ocr' },
      { id: 'glossary', label: 'Glossary Manager', sourceApp: 'training', route: '/glossary-manager', icon: 'activity-items', crossAppUrl: '/training/glossary-manager' },
      { id: 'registry', label: 'Model Registry', sourceApp: 'training', route: '/registry', icon: 'tags', crossAppUrl: '/training/registry' },
      { id: 'compare', label: 'Model Compare', sourceApp: 'training', route: '/compare', icon: 'compare', crossAppUrl: '/training/compare' },
      { id: 'pipeline', label: 'Training Pipeline', sourceApp: 'training', route: '/pipeline', icon: 'process', crossAppUrl: '/training/pipeline' },
      // aifabric-owned (local in this app)
      { id: 'deployments', label: 'Deployments', sourceApp: 'aifabric', route: '/deployments', icon: 'machine' },
      { id: 'streaming', label: 'Search Ops', sourceApp: 'aifabric', route: '/streaming', icon: 'search' },
      { id: 'governance', label: 'Governance', sourceApp: 'aifabric', route: '/governance', icon: 'shield' },
      { id: 'prompts', label: 'Prompt Library', sourceApp: 'aifabric', route: '/prompts', icon: 'document-text' },
      // ui5-owned
      { id: 'joule', label: 'Joule AI', sourceApp: 'joule', route: '/joule', icon: 'da', crossAppUrl: '/joule' },
    ],
    useCaseConfig: { dialect: 'msa', enableRTL: true, ocrEngine: 'tesseract-ar' },
    governancePolicyIds: ['policy-model-deploy', 'policy-training-data'],
    promptIds: ['seed-3'],
    collabRoomId: 'ws-arabic-finance',
    language: 'ar',
    defaultModel: 'arabic-finance-v2',
    createdAt: '2026-02-01T00:00:00Z',
    updatedAt: '2026-04-05T00:00:00Z',
  },
];
