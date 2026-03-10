// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * A2UI Component Registry
 *
 * Manages the allowlist of UI5 components that can be dynamically rendered.
 * Implements deny-unknown-components security policy.
 */

import { Injectable, Type } from '@angular/core';

// =============================================================================
// Types
// =============================================================================

/** Component metadata for registry */
export interface ComponentMetadata {
  /** Tag name (e.g., 'ui5-button') */
  tagName: string;
  /** Angular component class (if available) */
  componentClass?: Type<unknown>;
  /** Category for grouping */
  category: ComponentCategory;
  /** Allowed slots */
  slots?: string[];
  /** Allowed events */
  events?: string[];
  /** Whether this component is container (can have children) */
  isContainer?: boolean;
  /** Default props */
  defaultProps?: Record<string, unknown>;
}

/** Component categories */
export type ComponentCategory =
  | 'basic'      // Button, Label, Link, Icon
  | 'form'       // Input, Select, DatePicker, etc.
  | 'layout'     // Panel, FlexBox, Grid
  | 'data'       // Table, List, Tree
  | 'navigation' // Menu, Breadcrumbs, Tabs
  | 'feedback'   // MessageStrip, BusyIndicator, Dialog
  | 'chart'      // Charts (if available)
  | 'fiori'      // Fiori-specific components
  | 'custom';    // User-defined components

// =============================================================================
// Default Allowlist - UI5 Web Components (Fiori Standard)
// =============================================================================

const FIORI_STANDARD_COMPONENTS: ComponentMetadata[] = [
  // Basic components
  { tagName: 'ui5-button', category: 'basic', events: ['click'] },
  { tagName: 'ui5-label', category: 'basic' },
  { tagName: 'ui5-link', category: 'basic', events: ['click'] },
  { tagName: 'ui5-icon', category: 'basic' },
  { tagName: 'ui5-badge', category: 'basic' },
  { tagName: 'ui5-avatar', category: 'basic' },
  { tagName: 'ui5-avatar-group', category: 'basic', isContainer: true },
  { tagName: 'ui5-title', category: 'basic' },
  { tagName: 'ui5-text', category: 'basic' },
  
  // Form components
  { tagName: 'ui5-input', category: 'form', events: ['input', 'change'] },
  { tagName: 'ui5-textarea', category: 'form', events: ['input', 'change'] },
  { tagName: 'ui5-select', category: 'form', events: ['change'], isContainer: true },
  { tagName: 'ui5-option', category: 'form' },
  { tagName: 'ui5-combobox', category: 'form', events: ['change', 'input'], isContainer: true },
  { tagName: 'ui5-combobox-item', category: 'form' },
  { tagName: 'ui5-multi-combobox', category: 'form', events: ['selection-change'], isContainer: true },
  { tagName: 'ui5-multi-combobox-item', category: 'form' },
  { tagName: 'ui5-checkbox', category: 'form', events: ['change'] },
  { tagName: 'ui5-radio-button', category: 'form', events: ['change'] },
  { tagName: 'ui5-switch', category: 'form', events: ['change'] },
  { tagName: 'ui5-slider', category: 'form', events: ['change', 'input'] },
  { tagName: 'ui5-range-slider', category: 'form', events: ['change', 'input'] },
  { tagName: 'ui5-date-picker', category: 'form', events: ['change'] },
  { tagName: 'ui5-time-picker', category: 'form', events: ['change'] },
  { tagName: 'ui5-datetime-picker', category: 'form', events: ['change'] },
  { tagName: 'ui5-step-input', category: 'form', events: ['change'] },
  { tagName: 'ui5-rating-indicator', category: 'form', events: ['change'] },
  { tagName: 'ui5-color-picker', category: 'form', events: ['change'] },
  
  // Layout components
  { tagName: 'ui5-card', category: 'layout', isContainer: true, slots: ['header', 'default'] },
  { tagName: 'ui5-card-header', category: 'layout', events: ['click'] },
  { tagName: 'ui5-panel', category: 'layout', isContainer: true, events: ['toggle'] },
  { tagName: 'ui5-toolbar', category: 'layout', isContainer: true },
  { tagName: 'ui5-toolbar-button', category: 'layout', events: ['click'] },
  { tagName: 'ui5-toolbar-separator', category: 'layout' },
  { tagName: 'ui5-toolbar-spacer', category: 'layout' },
  { tagName: 'ui5-split-button', category: 'layout', events: ['click', 'arrow-click'] },
  { tagName: 'ui5-segmented-button', category: 'layout', events: ['selection-change'], isContainer: true },
  { tagName: 'ui5-segmented-button-item', category: 'layout' },
  { tagName: 'ui5-responsive-popover', category: 'layout', isContainer: true },
  { tagName: 'ui5-popover', category: 'layout', isContainer: true },
  
  // Data display components
  { tagName: 'ui5-table', category: 'data', isContainer: true, slots: ['columns', 'default'], events: ['row-click', 'selection-change'] },
  { tagName: 'ui5-table-column', category: 'data', isContainer: true },
  { tagName: 'ui5-table-row', category: 'data', isContainer: true },
  { tagName: 'ui5-table-cell', category: 'data', isContainer: true },
  { tagName: 'ui5-table-growing', category: 'data', events: ['load-more'] },
  { tagName: 'ui5-list', category: 'data', isContainer: true, events: ['item-click', 'selection-change'] },
  { tagName: 'ui5-li', category: 'data', isContainer: true, events: ['detail-click'] },
  { tagName: 'ui5-li-custom', category: 'data', isContainer: true },
  { tagName: 'ui5-li-groupheader', category: 'data' },
  { tagName: 'ui5-tree', category: 'data', isContainer: true, events: ['item-click', 'item-toggle'] },
  { tagName: 'ui5-tree-item', category: 'data', isContainer: true },
  { tagName: 'ui5-tree-item-custom', category: 'data', isContainer: true },
  
  // Navigation components
  { tagName: 'ui5-tabcontainer', category: 'navigation', isContainer: true, events: ['tab-select'] },
  { tagName: 'ui5-tab', category: 'navigation', isContainer: true },
  { tagName: 'ui5-tab-separator', category: 'navigation' },
  { tagName: 'ui5-breadcrumbs', category: 'navigation', isContainer: true, events: ['item-click'] },
  { tagName: 'ui5-breadcrumbs-item', category: 'navigation' },
  { tagName: 'ui5-menu', category: 'navigation', isContainer: true, events: ['item-click'] },
  { tagName: 'ui5-menu-item', category: 'navigation', isContainer: true },
  { tagName: 'ui5-side-navigation', category: 'navigation', isContainer: true, events: ['selection-change'] },
  { tagName: 'ui5-side-navigation-item', category: 'navigation', isContainer: true },
  { tagName: 'ui5-side-navigation-sub-item', category: 'navigation' },
  
  // Feedback components
  { tagName: 'ui5-message-strip', category: 'feedback', events: ['close'] },
  { tagName: 'ui5-toast', category: 'feedback' },
  { tagName: 'ui5-busy-indicator', category: 'feedback', isContainer: true },
  { tagName: 'ui5-progress-indicator', category: 'feedback' },
  { tagName: 'ui5-dialog', category: 'feedback', isContainer: true, slots: ['header', 'footer', 'default'], events: ['before-open', 'after-open', 'before-close', 'after-close'] },
  { tagName: 'ui5-bar', category: 'feedback', isContainer: true, slots: ['startContent', 'middleContent', 'endContent'] },
  
  // Fiori-specific components
  { tagName: 'ui5-shellbar', category: 'fiori', isContainer: true, slots: ['logo', 'profile', 'searchField', 'startButton', 'menuItems'], events: ['profile-click', 'logo-click', 'menu-item-click', 'notifications-click'] },
  { tagName: 'ui5-shellbar-item', category: 'fiori', events: ['click'] },
  { tagName: 'ui5-flexible-column-layout', category: 'fiori', isContainer: true, slots: ['startColumn', 'midColumn', 'endColumn'], events: ['layout-change'] },
  { tagName: 'ui5-dynamic-page', category: 'fiori', isContainer: true, slots: ['titleArea', 'headerArea', 'default'] },
  { tagName: 'ui5-dynamic-page-title', category: 'fiori', isContainer: true, slots: ['heading', 'snappedHeading', 'expandedHeading', 'actions', 'navigationActions', 'breadcrumbs', 'subheading', 'snappedSubheading', 'expandedSubheading'] },
  { tagName: 'ui5-dynamic-page-header', category: 'fiori', isContainer: true },
  { tagName: 'ui5-page', category: 'fiori', isContainer: true, slots: ['header', 'footer', 'default'] },
  { tagName: 'ui5-illustrated-message', category: 'fiori', isContainer: true },
  { tagName: 'ui5-wizard', category: 'fiori', isContainer: true, events: ['step-change'] },
  { tagName: 'ui5-wizard-step', category: 'fiori', isContainer: true },
  { tagName: 'ui5-timeline', category: 'fiori', isContainer: true },
  { tagName: 'ui5-timeline-item', category: 'fiori', events: ['name-click'] },
  { tagName: 'ui5-upload-collection', category: 'fiori', isContainer: true, events: ['item-delete', 'drop'] },
  { tagName: 'ui5-upload-collection-item', category: 'fiori', events: ['rename', 'retry', 'terminate'] },
  { tagName: 'ui5-notification-list', category: 'fiori', isContainer: true },
  { tagName: 'ui5-notification-list-item', category: 'fiori', events: ['close', 'detail-click'] },
  { tagName: 'ui5-notification-list-group-item', category: 'fiori', isContainer: true, events: ['toggle', 'close'] },
  { tagName: 'ui5-view-settings-dialog', category: 'fiori', events: ['confirm', 'cancel'] },
  { tagName: 'ui5-sort-item', category: 'fiori' },
  { tagName: 'ui5-filter-item', category: 'fiori', isContainer: true },
  { tagName: 'ui5-filter-item-option', category: 'fiori' },
  { tagName: 'ui5-product-switch', category: 'fiori', isContainer: true, events: ['item-click'] },
  { tagName: 'ui5-product-switch-item', category: 'fiori' },
  
  // AI components
  { tagName: 'ui5-ai-button', category: 'basic', events: ['click'] },
  { tagName: 'ui5-ai-prompt-input', category: 'form', events: ['submit', 'input'] },
];

// =============================================================================
// Security Deny List — file I/O and exfiltration-capable components
//
// These components MUST NOT be rendered by an agent-generated schema because
// they can exfiltrate data (file upload/download) or execute arbitrary scripts.
// They are denied at registry initialisation and cannot be re-allowed via allow().
// =============================================================================

export const SECURITY_DENY_LIST: ReadonlySet<string> = new Set([
  'ui5-file-uploader',    // triggers OS file-picker → potential data exfiltration
  'ui5-file-chooser',     // same risk as ui5-file-uploader
  'ui5-upload-collection',  // manages upload state; deny to prevent agent-driven upload flows
  'ui5-upload-collection-item', // child of upload-collection
]);

// =============================================================================
// Component Registry Service
// =============================================================================

@Injectable()
export class ComponentRegistry {
  private registry = new Map<string, ComponentMetadata>();
  private denyList = new Set<string>(SECURITY_DENY_LIST);

  constructor() {
    // Initialize with Fiori standard components
    this.loadFioriStandard();
  }

  /**
   * Load Fiori standard component allowlist
   */
  loadFioriStandard(): void {
    FIORI_STANDARD_COMPONENTS.forEach(meta => {
      // Never add security-denied components to the registry
      if (!SECURITY_DENY_LIST.has(meta.tagName)) {
        this.registry.set(meta.tagName, meta);
      }
    });
    // Ensure deny list is always enforced
    SECURITY_DENY_LIST.forEach(tag => this.denyList.add(tag));
  }

  /**
   * Register a component in the allowlist.
   * Components in SECURITY_DENY_LIST cannot be registered.
   */
  register(metadata: ComponentMetadata): void {
    if (SECURITY_DENY_LIST.has(metadata.tagName)) {
      throw new Error(`Component '${metadata.tagName}' is in the security deny list and cannot be registered.`);
    }
    this.registry.set(metadata.tagName, metadata);
    this.denyList.delete(metadata.tagName);
  }

  /**
   * Allow a component by tag name (simplified registration).
   * Components in SECURITY_DENY_LIST cannot be allowed.
   */
  allow(tagName: string, category: ComponentCategory = 'custom'): void {
    if (SECURITY_DENY_LIST.has(tagName)) {
      throw new Error(`Component '${tagName}' is in the security deny list and cannot be allowed.`);
    }
    if (!this.registry.has(tagName)) {
      this.registry.set(tagName, { tagName, category });
    }
    this.denyList.delete(tagName);
  }

  /**
   * Explicitly deny a component
   */
  deny(tagName: string): void {
    this.denyList.add(tagName);
  }

  /**
   * Check if a component is allowed
   */
  isAllowed(tagName: string): boolean {
    if (this.denyList.has(tagName)) return false;
    return this.registry.has(tagName);
  }

  /**
   * Get component metadata
   */
  get(tagName: string): ComponentMetadata | undefined {
    if (this.denyList.has(tagName)) return undefined;
    return this.registry.get(tagName);
  }

  /**
   * Get all registered components
   */
  getAll(): ComponentMetadata[] {
    return Array.from(this.registry.values())
      .filter(meta => !this.denyList.has(meta.tagName));
  }

  /**
   * Get components by category
   */
  getByCategory(category: ComponentCategory): ComponentMetadata[] {
    return this.getAll().filter(meta => meta.category === category);
  }

  /**
   * Check if a component is a container (can have children)
   */
  isContainer(tagName: string): boolean {
    const meta = this.get(tagName);
    return meta?.isContainer ?? false;
  }

  /**
   * Get allowed slots for a component
   */
  getSlots(tagName: string): string[] {
    const meta = this.get(tagName);
    return meta?.slots ?? ['default'];
  }

  /**
   * Get allowed events for a component
   */
  getEvents(tagName: string): string[] {
    const meta = this.get(tagName);
    return meta?.events ?? [];
  }

  /**
   * Clear the registry
   */
  clear(): void {
    this.registry.clear();
    this.denyList.clear();
  }

  /**
   * Reset to Fiori standard
   */
  reset(): void {
    this.clear();
    this.loadFioriStandard();
  }
}