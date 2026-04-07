export type AiFabricNavSectionId = 'operations' | 'support' | 'expert';

export interface AiFabricNavItem {
  id: string;
  text: string;
  textKey: string;
  icon: string;
  route: string;
  description: string;
  descriptionKey: string;
  section: AiFabricNavSectionId;
  tier: 'primary' | 'secondary' | 'expert';
}

export interface AiFabricNavSection {
  id: AiFabricNavSectionId;
  label: string;
  labelKey: string;
}

export const AI_FABRIC_NAV_ITEMS: AiFabricNavItem[] = [
  {
    id: 'dashboard',
    text: 'Dashboard',
    textKey: 'navigation.dashboard',
    icon: 'home',
    route: '/dashboard',
    description: 'View system overview and statistics',
    descriptionKey: 'navigation.descriptions.dashboard',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'deployments',
    text: 'Deployments',
    textKey: 'navigation.deployments',
    icon: 'machine',
    route: '/deployments',
    description: 'Manage AI model deployments',
    descriptionKey: 'navigation.descriptions.deployments',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'rag',
    text: 'Search Studio',
    textKey: 'navigation.searchStudio',
    icon: 'documents',
    route: '/rag',
    description: 'Elasticsearch-backed retrieval workspace',
    descriptionKey: 'navigation.descriptions.rag',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'data-quality',
    text: 'Data Quality',
    textKey: 'navigation.dataQuality',
    icon: 'validate',
    route: '/data-quality',
    description: 'AI-powered data validation and cleaning',
    descriptionKey: 'navigation.descriptions.dataQuality',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'governance',
    text: 'Governance',
    textKey: 'navigation.governance',
    icon: 'shield',
    route: '/governance',
    description: 'Configure governance rules and policies',
    descriptionKey: 'navigation.descriptions.governance',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'prompts',
    text: 'Prompt Library',
    textKey: 'navigation.promptLibrary',
    icon: 'document-text',
    route: '/prompts',
    description: 'Shared prompt templates for the team',
    descriptionKey: 'navigation.descriptions.prompts',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'prompts',
    text: 'Prompt Library',
    icon: 'document-text',
    route: '/prompts',
    description: 'Shared prompt templates for the team',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'data',
    text: 'Data Explorer',
    textKey: 'navigation.dataExplorer',
    icon: 'database',
    route: '/data',
    description: 'Explore vector stores and data',
    descriptionKey: 'navigation.descriptions.data',
    section: 'support',
    tier: 'secondary',
  },
  {
    id: 'lineage',
    text: 'Lineage',
    textKey: 'navigation.lineage',
    icon: 'org-chart',
    route: '/lineage',
    description: 'View data lineage and relationships',
    descriptionKey: 'navigation.descriptions.lineage',
    section: 'support',
    tier: 'secondary',
  },
  {
    id: 'streaming',
    text: 'Search Ops',
    textKey: 'navigation.searchOps',
    icon: 'search',
    route: '/streaming',
    description: 'Inspect Elasticsearch and PAL service state',
    descriptionKey: 'navigation.descriptions.streaming',
    section: 'expert',
    tier: 'expert',
  },
  {
    id: 'playground',
    text: 'PAL Workbench',
    textKey: 'navigation.palWorkbench',
    icon: 'lab',
    route: '/playground',
    description: 'Run PAL tools against registered data assets',
    descriptionKey: 'navigation.descriptions.playground',
    section: 'expert',
    tier: 'expert',
  },
  {
    id: 'workspace',
    text: 'Workspace',
    textKey: 'navigation.workspace',
    icon: 'action-settings',
    route: '/workspace',
    description: 'Workspace identity, backend, and navigation settings',
    descriptionKey: 'navigation.descriptions.workspace',
    section: 'expert',
    tier: 'expert',
  },
  {
    id: 'workspace',
    text: 'Workspace',
    icon: 'action-settings',
    route: '/workspace',
    description: 'Workspace identity, backend, and navigation settings',
    section: 'expert',
    tier: 'expert',
  },
];

export const AI_FABRIC_NAV_SECTIONS: AiFabricNavSection[] = [
  { id: 'operations', label: 'Core workflows', labelKey: 'navigation.sections.operations' },
  { id: 'support', label: 'Support data', labelKey: 'navigation.sections.support' },
  { id: 'expert', label: 'Expert tools', labelKey: 'navigation.sections.expert' },
];

export function resolveAiFabricSection(route: string): AiFabricNavSectionId {
  const normalizedRoute = route.split('?')[0].split('#')[0];
  const match = AI_FABRIC_NAV_ITEMS.find(
    (item) => normalizedRoute === item.route || normalizedRoute.startsWith(`${item.route}/`),
  );
  return match?.section ?? 'operations';
}
