// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

/** Current A2UI schema version produced by this library */
export const A2UI_SCHEMA_VERSION = '1' as const;

/** A2UI component schema */
export interface A2UiSchema {
  /** Component tag name */
  component: string;
  /** Unique ID for this instance */
  id?: string;
  /**
   * Schema version for forward-compatibility.
   * Agents should set this to the value of A2UI_SCHEMA_VERSION ('1').
   * The renderer warns (never rejects) on unknown versions to stay backward-compatible.
   */
  schemaVersion?: string;
  /** Component properties */
  props?: Record<string, unknown>;
  /** Child components */
  children?: A2UiSchema[];
  /** Slot assignments */
  slots?: Record<string, A2UiSchema | A2UiSchema[]>;
  /** Event handlers (mapped to callbacks) */
  events?: Record<string, EventHandler>;
  /** Data bindings */
  bindings?: Record<string, DataBinding>;
  /** Conditional rendering */
  if?: string;
  /** List rendering */
  for?: { items: string; as: string; key?: string };
  /** CSS classes */
  class?: string | string[];
  /** Inline styles */
  style?: Record<string, string>;
}

/** Event handler definition */
export interface EventHandler {
  /** Tool to invoke on event */
  toolName: string;
  /** Arguments to pass to tool */
  arguments?: Record<string, unknown>;
  /** Custom callback (alternative to tool) */
  callback?: (event: Event) => void;
}

/** Data binding definition */
export interface DataBinding {
  /** Data source identifier */
  source: string;
  /** Path within the source */
  path: string;
  /** Optional transform expression */
  transform?: string;
  /** Two-way binding */
  twoWay?: boolean;
}

/** Rendered component instance */
export interface RenderedComponent {
  /** Unique instance ID */
  id: string;
  /** Schema used to create this instance */
  schema: A2UiSchema;
  /** Native DOM element */
  element: HTMLElement;
  /** Child instances */
  children: RenderedComponent[];
  /** Parent instance ID */
  parentId?: string;
  /** Slot name if in a slot */
  slot?: string;
}

/** Render context for data binding */
export interface RenderContext {
  /** Data sources */
  data: Record<string, unknown>;
  /** Event callbacks */
  onEvent?: (eventName: string, handler: EventHandler, event: Event) => void;
  /** Parent context */
  parent?: RenderContext;
}
