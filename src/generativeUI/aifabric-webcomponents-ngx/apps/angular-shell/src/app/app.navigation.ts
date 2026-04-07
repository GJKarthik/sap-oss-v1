export type AiFabricNavSectionId = 'operations' | 'support' | 'expert';

export interface AiFabricNavItem {
  id: string;
  text: string;
  icon: string;
  route: string;
  description: string;
  section: AiFabricNavSectionId;
  tier: 'primary' | 'secondary' | 'expert';
}

export interface AiFabricNavSection {
  id: AiFabricNavSectionId;
  label: string;
}

export const AI_FABRIC_NAV_ITEMS: AiFabricNavItem[] = [
  {
    id: 'dashboard',
    text: 'Dashboard',
    icon: 'home',
    route: '/dashboard',
    description: 'View system overview and statistics',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'deployments',
    text: 'Deployments',
    icon: 'machine',
    route: '/deployments',
    description: 'Manage AI model deployments',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'rag',
    text: 'Search Studio',
    icon: 'documents',
    route: '/rag',
    description: 'Elasticsearch-backed retrieval workspace',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'data-quality',
    text: 'Data Quality',
    icon: 'validate',
    route: '/data-quality',
    description: 'AI-powered data validation and cleaning',
    section: 'operations',
    tier: 'primary',
  },
  {
    id: 'governance',
    text: 'Governance',
    icon: 'shield',
    route: '/governance',
    description: 'Configure governance rules and policies',
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
    icon: 'database',
    route: '/data',
    description: 'Explore vector stores and data',
    section: 'support',
    tier: 'secondary',
  },
  {
    id: 'lineage',
    text: 'Lineage',
    icon: 'org-chart',
    route: '/lineage',
    description: 'View data lineage and relationships',
    section: 'support',
    tier: 'secondary',
  },
  {
    id: 'streaming',
    text: 'Search Ops',
    icon: 'search',
    route: '/streaming',
    description: 'Inspect Elasticsearch and PAL service state',
    section: 'expert',
    tier: 'expert',
  },
  {
    id: 'playground',
    text: 'PAL Workbench',
    icon: 'lab',
    route: '/playground',
    description: 'Run PAL tools against registered data assets',
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
  { id: 'operations', label: 'Core workflows' },
  { id: 'support', label: 'Support data' },
  { id: 'expert', label: 'Expert tools' },
];

export function resolveAiFabricSection(route: string): AiFabricNavSectionId {
  const normalizedRoute = route.split('?')[0].split('#')[0];
  const match = AI_FABRIC_NAV_ITEMS.find(
    (item) => normalizedRoute === item.route || normalizedRoute.startsWith(`${item.route}/`),
  );
  return match?.section ?? 'operations';
}
