// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Dynamic Component Renderer
 *
 * Renders A2UI schemas into real UI5 Angular components at runtime.
 * Uses Angular's ComponentFactoryResolver for dynamic instantiation.
 */

import {
  Injectable,
  Optional,
  ViewContainerRef,
  ComponentRef,
  Renderer2,
  RendererFactory2,
  ElementRef,
  Injector,
  createComponent,
  EnvironmentInjector,
} from '@angular/core';
import { Subject, BehaviorSubject } from 'rxjs';
import { ComponentRegistry, ComponentMetadata } from '../registry/component-registry';
import { SchemaValidator, ValidationResult } from '../validation/schema-validator';

// =============================================================================
// Types
// =============================================================================

/** A2UI component schema */
export interface A2UiSchema {
  /** Component tag name */
  component: string;
  /** Unique ID for this instance */
  id?: string;
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

// =============================================================================
// Dynamic Renderer Service
// =============================================================================

@Injectable({ providedIn: 'root' })
export class DynamicRenderer {
  private renderer: Renderer2;
  private instances = new Map<string, RenderedComponent>();
  private idCounter = 0;

  /** Observable of rendered instances */
  readonly instances$ = new BehaviorSubject<Map<string, RenderedComponent>>(new Map());

  /** Emits when a component is rendered */
  readonly componentRendered$ = new Subject<RenderedComponent>();

  /** Emits when a component is destroyed */
  readonly componentDestroyed$ = new Subject<string>();

  constructor(
    private registry: ComponentRegistry,
    private validator: SchemaValidator,
    rendererFactory: RendererFactory2,
    @Optional() private environmentInjector: EnvironmentInjector | null
  ) {
    this.renderer = rendererFactory.createRenderer(null, null);
  }

  /**
   * Render an A2UI schema into a container
   */
  render(
    schema: A2UiSchema,
    container: HTMLElement | ViewContainerRef,
    context: RenderContext = { data: {} }
  ): RenderedComponent | null {
    // Validate schema
    const validation = this.validator.validate(schema);
    if (!validation.valid) {
      console.error('[DynamicRenderer] Schema validation failed:', validation.errors);
      return null;
    }

    // Get container element
    const containerEl = container instanceof HTMLElement
      ? container
      : (container as ViewContainerRef).element.nativeElement;

    // Render the component
    return this.renderComponent(schema, containerEl, context);
  }

  /**
   * Render a single component
   */
  private renderComponent(
    schema: A2UiSchema,
    container: HTMLElement,
    context: RenderContext,
    slot?: string
  ): RenderedComponent | null {
    // Check if component is allowed
    if (!this.registry.isAllowed(schema.component)) {
      console.warn(`[DynamicRenderer] Component '${schema.component}' is not allowed`);
      return null;
    }

    // Check conditional rendering
    if (schema.if && !this.evaluateCondition(schema.if, context)) {
      return null;
    }

    // Handle list rendering
    if (schema.for) {
      return this.renderList(schema, container, context, slot);
    }

    // Generate unique ID
    const id = schema.id || this.generateId();

    // Prefer Angular createComponent() when a componentClass is registered;
    // fall back to createElement() for standard web components / custom elements.
    const meta = this.registry.get(schema.component);
    let angularRef: ComponentRef<unknown> | null = null;
    let element: HTMLElement;

    if (meta?.componentClass && this.environmentInjector) {
      try {
        angularRef = createComponent(meta.componentClass, {
          environmentInjector: this.environmentInjector,
          hostElement: this.renderer.createElement(schema.component) as HTMLElement,
        });
        element = angularRef.location.nativeElement as HTMLElement;
      } catch (e) {
        console.warn(`[DynamicRenderer] createComponent failed for '${schema.component}', falling back to createElement:`, e);
        element = this.renderer.createElement(schema.component) as HTMLElement;
      }
    } else {
      // Standard path: custom element / web component
      element = this.renderer.createElement(schema.component) as HTMLElement;
    }

    // Apply props
    if (schema.props) {
      this.applyProps(element, schema.props, context);
    }

    // Apply bindings
    if (schema.bindings) {
      this.applyBindings(element, schema.bindings, context);
    }

    // Apply classes
    if (schema.class) {
      this.applyClasses(element, schema.class);
    }

    // Apply styles
    if (schema.style) {
      this.applyStyles(element, schema.style);
    }

    // Apply events
    if (schema.events) {
      this.applyEvents(element, schema.events, context);
    }

    // Set slot attribute if provided
    if (slot && slot !== 'default') {
      this.renderer.setAttribute(element, 'slot', slot);
    }

    // Create instance record
    const instance: RenderedComponent = {
      id,
      schema,
      element,
      children: [],
      slot,
    };

    // Render children
    if (schema.children) {
      for (const childSchema of schema.children) {
        const childInstance = this.renderComponent(childSchema, element, context);
        if (childInstance) {
          childInstance.parentId = id;
          instance.children.push(childInstance);
        }
      }
    }

    // Render slots
    if (schema.slots) {
      for (const [slotName, slotContent] of Object.entries(schema.slots)) {
        const contents = Array.isArray(slotContent) ? slotContent : [slotContent];
        for (const slotSchema of contents) {
          const slotInstance = this.renderComponent(slotSchema, element, context, slotName);
          if (slotInstance) {
            slotInstance.parentId = id;
            slotInstance.slot = slotName;
            instance.children.push(slotInstance);
          }
        }
      }
    }

    // Append to container
    this.renderer.appendChild(container, element);

    // Store instance
    this.instances.set(id, instance);
    this.instances$.next(new Map(this.instances));
    this.componentRendered$.next(instance);

    return instance;
  }

  /**
   * Render a list of components
   */
  private renderList(
    schema: A2UiSchema,
    container: HTMLElement,
    context: RenderContext,
    slot?: string
  ): RenderedComponent | null {
    if (!schema.for) return null;

    const items = this.resolvePath(context.data, schema.for.items);
    if (!Array.isArray(items)) {
      console.warn(`[DynamicRenderer] for.items '${schema.for.items}' is not an array`);
      return null;
    }

    const containerId = this.generateId();
    const wrapper = this.renderer.createElement('div');
    this.renderer.setAttribute(wrapper, 'data-genui-list', containerId);

    const instance: RenderedComponent = {
      id: containerId,
      schema,
      element: wrapper,
      children: [],
      slot,
    };

    items.forEach((item, index) => {
      const itemContext: RenderContext = {
        ...context,
        data: {
          ...context.data,
          [schema.for!.as]: item,
          $index: index,
        },
      };

      // Create schema without `for` to avoid infinite recursion
      const itemSchema: A2UiSchema = {
        ...schema,
        for: undefined,
        id: schema.for!.key ? `${containerId}-${this.resolvePath(item, schema.for!.key)}` : undefined,
      };

      const childInstance = this.renderComponent(itemSchema, wrapper, itemContext);
      if (childInstance) {
        childInstance.parentId = containerId;
        instance.children.push(childInstance);
      }
    });

    this.renderer.appendChild(container, wrapper);
    this.instances.set(containerId, instance);

    return instance;
  }

  /**
   * Update an existing component
   */
  update(id: string, updates: Partial<A2UiSchema>, context?: RenderContext): boolean {
    const instance = this.instances.get(id);
    if (!instance) return false;

    const ctx = context || { data: {} };

    // Update props
    if (updates.props) {
      this.applyProps(instance.element, updates.props, ctx);
      instance.schema.props = { ...instance.schema.props, ...updates.props };
    }

    // Update bindings
    if (updates.bindings) {
      this.applyBindings(instance.element, updates.bindings, ctx);
    }

    // Update classes
    if (updates.class) {
      this.applyClasses(instance.element, updates.class);
    }

    // Update styles
    if (updates.style) {
      this.applyStyles(instance.element, updates.style);
    }

    return true;
  }

  /**
   * Remove a component
   */
  remove(id: string, animate = false): boolean {
    const instance = this.instances.get(id);
    if (!instance) return false;

    // Remove children first
    for (const child of instance.children) {
      this.remove(child.id, false);
    }

    // Remove from DOM
    if (animate) {
      instance.element.classList.add('genui-removing');
      setTimeout(() => {
        this.renderer.removeChild(instance.element.parentNode, instance.element);
      }, 300);
    } else {
      this.renderer.removeChild(instance.element.parentNode, instance.element);
    }

    // Remove from registry
    this.instances.delete(id);
    this.instances$.next(new Map(this.instances));
    this.componentDestroyed$.next(id);

    return true;
  }

  /**
   * Clear all rendered components
   */
  clear(): void {
    for (const id of this.instances.keys()) {
      this.remove(id);
    }
  }

  /**
   * Get a rendered instance by ID
   */
  getInstance(id: string): RenderedComponent | undefined {
    return this.instances.get(id);
  }

  /**
   * Apply props to an element
   */
  private applyProps(element: HTMLElement, props: Record<string, unknown>, context: RenderContext): void {
    for (const [key, value] of Object.entries(props)) {
      // Skip special props
      if (key === 'slot') {
        this.renderer.setAttribute(element, 'slot', String(value));
        continue;
      }

      // Resolve value if it's a binding expression
      const resolvedValue = this.resolveValue(value, context);

      // Set as property or attribute
      if (key in element) {
        (element as Record<string, unknown>)[key] = resolvedValue;
      } else {
        this.renderer.setAttribute(element, key, String(resolvedValue));
      }
    }
  }

  /**
   * Apply data bindings
   */
  private applyBindings(element: HTMLElement, bindings: Record<string, DataBinding>, context: RenderContext): void {
    for (const [prop, binding] of Object.entries(bindings)) {
      const value = this.resolvePath(context.data, `${binding.source}.${binding.path}`);
      
      if (value !== undefined) {
        const transformedValue = binding.transform
          ? this.applyTransform(value, binding.transform)
          : value;

        if (prop in element) {
          (element as Record<string, unknown>)[prop] = transformedValue;
        } else {
          this.renderer.setAttribute(element, prop, String(transformedValue));
        }
      }
    }
  }

  /**
   * Apply CSS classes
   */
  private applyClasses(element: HTMLElement, classes: string | string[]): void {
    const classList = Array.isArray(classes) ? classes : classes.split(' ');
    classList.forEach(cls => {
      if (cls.trim()) {
        this.renderer.addClass(element, cls.trim());
      }
    });
  }

  /**
   * Apply inline styles
   */
  private applyStyles(element: HTMLElement, styles: Record<string, string>): void {
    for (const [prop, value] of Object.entries(styles)) {
      this.renderer.setStyle(element, prop, value);
    }
  }

  /**
   * Apply event handlers
   */
  private applyEvents(element: HTMLElement, events: Record<string, EventHandler>, context: RenderContext): void {
    for (const [eventName, handler] of Object.entries(events)) {
      this.renderer.listen(element, eventName, (event: Event) => {
        if (handler.callback) {
          handler.callback(event);
        } else if (context.onEvent) {
          context.onEvent(eventName, handler, event);
        }
      });
    }
  }

  /**
   * Evaluate a conditional expression
   */
  private evaluateCondition(condition: string, context: RenderContext): boolean {
    try {
      const value = this.resolvePath(context.data, condition);
      return Boolean(value);
    } catch {
      return false;
    }
  }

  /**
   * Resolve a path in an object
   */
  private resolvePath(obj: unknown, path: string): unknown {
    if (!path) return obj;
    
    const parts = path.split('.');
    let current: unknown = obj;

    for (const part of parts) {
      if (current === null || current === undefined) return undefined;
      current = (current as Record<string, unknown>)[part];
    }

    return current;
  }

  /**
   * Resolve a value that may be a binding expression
   */
  private resolveValue(value: unknown, context: RenderContext): unknown {
    if (typeof value === 'string' && value.startsWith('{{') && value.endsWith('}}')) {
      const path = value.slice(2, -2).trim();
      return this.resolvePath(context.data, path);
    }
    return value;
  }

  /**
   * Apply a transform to a value
   */
  private applyTransform(value: unknown, transform: string): unknown {
    // Simple transforms
    switch (transform) {
      case 'uppercase':
        return String(value).toUpperCase();
      case 'lowercase':
        return String(value).toLowerCase();
      case 'number':
        return Number(value);
      case 'string':
        return String(value);
      case 'boolean':
        return Boolean(value);
      case 'json':
        return JSON.stringify(value);
      default:
        return value;
    }
  }

  /**
   * Generate a unique ID
   */
  private generateId(): string {
    return `genui-${++this.idCounter}-${Date.now().toString(36)}`;
  }
}