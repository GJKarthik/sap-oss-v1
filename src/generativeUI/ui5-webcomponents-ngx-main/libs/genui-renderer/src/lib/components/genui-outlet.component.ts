// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Outlet Component
 *
 * Angular component that renders A2UI schemas into UI5 components.
 * Acts as a container for dynamically generated UI.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ElementRef,
  OnChanges,
  OnDestroy,
  SimpleChanges,
  ChangeDetectionStrategy,
} from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import {
  DynamicRenderer,
  A2UiSchema,
  RenderedComponent,
  RenderContext,
  EventHandler,
} from '../renderer/dynamic-renderer.service';

/** Event emitted when an A2UI event handler is triggered */
export interface GenUiEvent {
  /** Event name */
  eventName: string;
  /** Event handler configuration */
  handler: EventHandler;
  /** Original DOM event */
  originalEvent: Event;
  /** Component ID that triggered the event */
  componentId?: string;
}

@Component({
  selector: 'genui-outlet',
  template: `<ng-content></ng-content>`,
  styles: [`
    :host {
      display: block;
    }
    :host.genui-loading {
      opacity: 0.5;
    }
    :host ::ng-deep .genui-removing {
      opacity: 0;
      transition: opacity 0.3s ease-out;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GenUiOutletComponent implements OnChanges, OnDestroy {
  /** A2UI schema to render */
  @Input() schema: A2UiSchema | null = null;

  /** Data context for bindings */
  @Input() data: Record<string, unknown> = {};

  /** Whether to animate changes */
  @Input() animate = true;

  /** Whether to clear existing content on schema change */
  @Input() clearOnChange = true;

  /** Emits when an event handler is triggered */
  @Output() genUiEvent = new EventEmitter<GenUiEvent>();

  /** Emits when a component is rendered */
  @Output() componentRendered = new EventEmitter<RenderedComponent>();

  /** Emits when rendering completes */
  @Output() renderComplete = new EventEmitter<void>();

  /** Emits on render error */
  @Output() renderError = new EventEmitter<Error>();

  private destroy$ = new Subject<void>();
  private currentInstance: RenderedComponent | null = null;

  constructor(
    private renderer: DynamicRenderer,
    private elementRef: ElementRef<HTMLElement>
  ) {
    // Subscribe to renderer events
    this.renderer.componentRendered$
      .pipe(takeUntil(this.destroy$))
      .subscribe(instance => {
        this.componentRendered.emit(instance);
      });
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['schema'] || changes['data']) {
      this.render();
    }
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
    this.clear();
  }

  /**
   * Render the schema
   */
  render(): void {
    if (!this.schema) {
      this.clear();
      return;
    }

    try {
      // Clear existing content if configured
      if (this.clearOnChange && this.currentInstance) {
        this.renderer.remove(this.currentInstance.id, false);
        this.currentInstance = null;
      }

      // Create render context
      const context: RenderContext = {
        data: this.data,
        onEvent: (eventName, handler, event) => {
          this.genUiEvent.emit({
            eventName,
            handler,
            originalEvent: event,
            componentId: this.currentInstance?.id,
          });
        },
      };

      // Render the schema
      this.elementRef.nativeElement.classList.add('genui-loading');
      
      this.currentInstance = this.renderer.render(
        this.schema,
        this.elementRef.nativeElement,
        context
      );

      this.elementRef.nativeElement.classList.remove('genui-loading');

      if (this.currentInstance) {
        this.renderComplete.emit();
      }
    } catch (error) {
      this.elementRef.nativeElement.classList.remove('genui-loading');
      this.renderError.emit(error instanceof Error ? error : new Error(String(error)));
    }
  }

  /**
   * Update the rendered content
   */
  update(updates: Partial<A2UiSchema>): boolean {
    if (!this.currentInstance) return false;

    return this.renderer.update(
      this.currentInstance.id,
      updates,
      { data: this.data }
    );
  }

  /**
   * Clear the rendered content
   */
  clear(): void {
    if (this.currentInstance) {
      this.renderer.remove(this.currentInstance.id, this.animate);
      this.currentInstance = null;
    }
  }

  /**
   * Get the current rendered instance
   */
  getInstance(): RenderedComponent | null {
    return this.currentInstance;
  }

  /**
   * Get the native element
   */
  getNativeElement(): HTMLElement {
    return this.elementRef.nativeElement;
  }
}