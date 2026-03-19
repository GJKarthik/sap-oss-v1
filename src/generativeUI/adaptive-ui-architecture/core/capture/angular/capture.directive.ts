/**
 * Adaptive UI Architecture — Angular Capture Directives
 * 
 * Drop-in directives for capturing interactions in Angular components.
 * Add these to existing components without modifying their logic.
 */

import {
  Directive,
  Input,
  HostListener,
  OnInit,
  OnDestroy,
  ElementRef,
  NgZone,
} from '@angular/core';
import { captureService } from '../capture-service';
import type { InteractionType } from '../types';

// ============================================================================
// BASE CAPTURE DIRECTIVE
// ============================================================================

@Directive({
  selector: '[adaptiveCapture]',
  standalone: true,
})
export class AdaptiveCaptureDirective implements OnInit, OnDestroy {
  /** Component type identifier */
  @Input('adaptiveCapture') componentType = 'unknown';
  
  /** Unique component instance ID */
  @Input() captureId = '';
  
  /** Target identifier for the element */
  @Input() captureTarget = '';
  
  /** Additional metadata to include */
  @Input() captureMetadata: Record<string, unknown> = {};
  
  /** Events to capture (default: click, focus) */
  @Input() captureEvents: InteractionType[] = ['click', 'focus'];

  private hoverStartTime: number | null = null;
  private focusStartTime: number | null = null;
  private componentId: string = '';

  constructor(
    private el: ElementRef<HTMLElement>,
    private zone: NgZone
  ) {}

  ngOnInit(): void {
    this.componentId = this.captureId || this.generateId();
    
    // Set up passive scroll listener if needed
    if (this.captureEvents.includes('scroll')) {
      this.zone.runOutsideAngular(() => {
        this.el.nativeElement.addEventListener('scroll', this.onScroll, { passive: true });
      });
    }
  }

  ngOnDestroy(): void {
    this.el.nativeElement.removeEventListener('scroll', this.onScroll);
  }

  private generateId(): string {
    return `${this.componentType}-${Math.random().toString(36).slice(2, 9)}`;
  }

  private capture(type: InteractionType, metadata: Record<string, unknown> = {}): void {
    if (!this.captureEvents.includes(type)) return;
    
    captureService.capture({
      type,
      target: this.captureTarget || this.el.nativeElement.tagName.toLowerCase(),
      componentType: this.componentType,
      componentId: this.componentId,
      metadata: { ...this.captureMetadata, ...metadata },
    });
  }

  @HostListener('click', ['$event'])
  onClick(event: MouseEvent): void {
    this.capture('click', {
      x: event.clientX,
      y: event.clientY,
      button: event.button,
    });
  }

  @HostListener('mouseenter')
  onMouseEnter(): void {
    if (this.captureEvents.includes('hover')) {
      this.hoverStartTime = Date.now();
    }
  }

  @HostListener('mouseleave')
  onMouseLeave(): void {
    if (this.hoverStartTime && this.captureEvents.includes('hover')) {
      const duration = Date.now() - this.hoverStartTime;
      if (duration > 200) {
        this.capture('hover', { durationMs: duration });
      }
      this.hoverStartTime = null;
    }
  }

  @HostListener('focus')
  onFocus(): void {
    this.focusStartTime = Date.now();
    this.capture('focus');
  }

  @HostListener('blur')
  onBlur(): void {
    if (this.focusStartTime) {
      const duration = Date.now() - this.focusStartTime;
      this.capture('blur', { focusDurationMs: duration });
      this.focusStartTime = null;
    }
  }

  private onScroll = (): void => {
    // Debounced in actual implementation
    const el = this.el.nativeElement;
    this.capture('scroll', {
      scrollTop: el.scrollTop,
      scrollLeft: el.scrollLeft,
      scrollHeight: el.scrollHeight,
      clientHeight: el.clientHeight,
    });
  };
}

// ============================================================================
// TABLE CAPTURE DIRECTIVE
// ============================================================================

@Directive({
  selector: '[adaptiveCaptureTable]',
  standalone: true,
})
export class AdaptiveCaptureTableDirective {
  @Input('adaptiveCaptureTable') tableId = '';
  @Input() captureMetadata: Record<string, unknown> = {};

  private componentId: string = '';

  constructor() {
    this.componentId = this.tableId || `table-${Math.random().toString(36).slice(2, 9)}`;
  }

  /** Call this when a column is sorted */
  captureSort(column: string, direction: 'asc' | 'desc'): void {
    captureService.capture({
      type: 'sort',
      target: column,
      componentType: 'table',
      componentId: this.componentId,
      metadata: { column, direction, ...this.captureMetadata },
    });
  }

  /** Call this when pagination changes */
  capturePagination(page: number, pageSize: number): void {
    captureService.capture({
      type: 'navigate',
      target: 'pagination',
      componentType: 'table',
      componentId: this.componentId,
      metadata: { page, pageSize, ...this.captureMetadata },
    });
  }

  /** Call this when a row is expanded */
  captureRowExpand(rowIndex: number, expanded: boolean): void {
    captureService.capture({
      type: expanded ? 'expand' : 'collapse',
      target: `row-${rowIndex}`,
      componentType: 'table',
      componentId: this.componentId,
      metadata: { rowIndex, expanded, ...this.captureMetadata },
    });
  }
}

