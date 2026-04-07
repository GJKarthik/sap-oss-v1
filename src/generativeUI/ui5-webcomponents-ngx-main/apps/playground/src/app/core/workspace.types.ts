// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { environment } from '../../environments/environment';

// ---------------------------------------------------------------------------
// Workspace Settings Model
// ---------------------------------------------------------------------------

export interface WorkspaceIdentity {
  userId: string;
  displayName: string;
  teamName: string;
}

export interface WorkspaceBackendConfig {
  openAiBaseUrl: string;
  mcpBaseUrl: string;
  agUiEndpoint: string;
  collabWsUrl: string;
  ocrInternalToken: string;
}

export interface WorkspaceNavItem {
  path: string;
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
  moduleOverrides: Record<string, { model?: string; temperature?: number; systemPrompt?: string }>;
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

// ---------------------------------------------------------------------------
// Navigation Link Data
// ---------------------------------------------------------------------------

export interface NavLinkDatum {
  path: string;
  labelKey: string;
  icon: string;
  titleKey: string;
  subtitleKey: string;
  descriptionKey: string;
  buttonKey: string;
  showInShellbar: boolean;
  showOnHome: boolean;
}

export const NAV_LINK_DATA: NavLinkDatum[] = [
  {
    path: '/forms',
    labelKey: 'NAV_FORMS',
    icon: 'form',
    titleKey: 'HOME_CARD_FORMS_TITLE',
    subtitleKey: 'HOME_CARD_FORMS_SUBTITLE',
    descriptionKey: 'HOME_CARD_FORMS_DESC',
    buttonKey: 'HOME_CARD_FORMS_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/joule',
    labelKey: 'NAV_JOULE',
    icon: 'ai',
    titleKey: 'HOME_CARD_JOULE_TITLE',
    subtitleKey: 'HOME_CARD_JOULE_SUBTITLE',
    descriptionKey: 'HOME_CARD_JOULE_DESC',
    buttonKey: 'HOME_CARD_JOULE_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/collab',
    labelKey: 'NAV_COLLAB',
    icon: 'collaborate',
    titleKey: 'HOME_CARD_COLLAB_TITLE',
    subtitleKey: 'HOME_CARD_COLLAB_SUBTITLE',
    descriptionKey: 'HOME_CARD_COLLAB_DESC',
    buttonKey: 'HOME_CARD_COLLAB_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/generative',
    labelKey: 'NAV_GENERATIVE',
    icon: 'palette',
    titleKey: 'HOME_CARD_GENERATIVE_TITLE',
    subtitleKey: 'HOME_CARD_GENERATIVE_SUBTITLE',
    descriptionKey: 'HOME_CARD_GENERATIVE_DESC',
    buttonKey: 'HOME_CARD_GENERATIVE_BTN',
    showInShellbar: false,
    showOnHome: true,
  },
  {
    path: '/components',
    labelKey: 'NAV_COMPONENTS',
    icon: 'palette',
    titleKey: 'HOME_CARD_COMPONENTS_TITLE',
    subtitleKey: 'HOME_CARD_COMPONENTS_SUBTITLE',
    descriptionKey: 'HOME_CARD_COMPONENTS_DESC',
    buttonKey: 'HOME_CARD_COMPONENTS_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/mcp',
    labelKey: 'NAV_MCP',
    icon: 'chain-link',
    titleKey: 'HOME_CARD_MCP_TITLE',
    subtitleKey: 'HOME_CARD_MCP_SUBTITLE',
    descriptionKey: 'HOME_CARD_MCP_DESC',
    buttonKey: 'HOME_CARD_MCP_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/ocr',
    labelKey: 'NAV_OCR',
    icon: 'doc-attachment',
    titleKey: 'HOME_CARD_OCR_TITLE',
    subtitleKey: 'HOME_CARD_OCR_SUBTITLE',
    descriptionKey: 'HOME_CARD_OCR_DESC',
    buttonKey: 'HOME_CARD_OCR_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/readiness',
    labelKey: 'NAV_READINESS',
    icon: 'checklist',
    titleKey: 'HOME_CARD_READINESS_TITLE',
    subtitleKey: 'HOME_CARD_READINESS_SUBTITLE',
    descriptionKey: 'HOME_CARD_READINESS_DESC',
    buttonKey: 'HOME_CARD_READINESS_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
  {
    path: '/workspace',
    labelKey: 'NAV_WORKSPACE',
    icon: 'action-settings',
    titleKey: 'HOME_CARD_WORKSPACE_TITLE',
    subtitleKey: 'HOME_CARD_WORKSPACE_SUBTITLE',
    descriptionKey: 'HOME_CARD_WORKSPACE_DESC',
    buttonKey: 'HOME_CARD_WORKSPACE_BTN',
    showInShellbar: true,
    showOnHome: true,
  },
];

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

function generateUserId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return 'ws-user-' + crypto.randomUUID().slice(0, 4).toLowerCase();
  }
  return 'ws-user-' + Date.now().toString(36).slice(-4);
}

export function createDefaultWorkspaceSettings(): WorkspaceSettings {
  const storedUserId = typeof localStorage !== 'undefined'
    ? localStorage.getItem('playground.workspace.userId')
    : null;
  const userId = storedUserId || generateUserId();
  if (!storedUserId && typeof localStorage !== 'undefined') {
    localStorage.setItem('playground.workspace.userId', userId);
  }

  return {
    version: 1,
    identity: {
      userId,
      displayName: 'Playground User',
      teamName: '',
    },
    backend: {
      openAiBaseUrl: environment.openAiBaseUrl,
      mcpBaseUrl: environment.mcpBaseUrl,
      agUiEndpoint: environment.agUiEndpoint,
      collabWsUrl: environment.collabWsUrl,
      ocrInternalToken: environment.ocrInternalToken,
    },
    nav: {
      defaultLandingPath: '/',
      items: NAV_LINK_DATA.map((link, i) => ({
        path: link.path,
        visible: true,
        order: i,
      })),
    },
    model: {
      defaultModel: '',
      temperature: 0.7,
      systemPrompt: '',
      moduleOverrides: {},
    },
    theme: 'sap_horizon',
    language: 'en',
    updatedAt: new Date().toISOString(),
  };
}
