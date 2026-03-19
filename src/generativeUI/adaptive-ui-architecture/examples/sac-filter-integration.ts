/**
 * Example: Integrating Capture with SAC Filter Component
 * 
 * This shows how to add adaptive capture to an existing component
 * WITHOUT modifying its core logic.
 */

import { Component, OnInit, OnDestroy, Input, Output, EventEmitter } from '@angular/core';
import { createCaptureHooks } from '../core/capture/capture-hooks';
import { contextProvider } from '../core/context/context-provider';
import type { AdaptiveContext } from '../core/context/types';
import type { CaptureHooks } from '../core/capture/capture-hooks';

// ============================================================================
// ORIGINAL COMPONENT (reference)
// ============================================================================

// This is a simplified version of the SAC Filter component.
// In practice, you'd extend or wrap the existing component.

@Component({
  selector: 'sac-filter-adaptive',
  template: `
    <div class="sac-filter"
         [class.density-compact]="density === 'compact'"
         [class.density-comfortable]="density === 'comfortable'"
         role="group"
         [attr.aria-label]="'Filter: ' + label">
      
      <!-- Show suggested filters if we have learned patterns -->
      <div *ngIf="suggestedValues.length > 0" 
           class="suggested-filters"
           role="region"
           aria-label="Frequently used values">
        <span class="suggestion-label">Quick:</span>
        <button *ngFor="let val of suggestedValues"
                class="quick-filter"
                (click)="selectValue(val)"
                type="button">
          {{ val }}
        </button>
      </div>

      <label [id]="labelId">{{ label }}</label>
      
      <select [attr.aria-labelledby]="labelId"
              [value]="value"
              (change)="onFilterChange($event)">
        <option value="">All</option>
        <option *ngFor="let opt of options" [value]="opt.value">
          {{ opt.label }}
        </option>
      </select>
      
      <button *ngIf="value" 
              class="clear-btn"
              (click)="clearFilter()"
              type="button"
              aria-label="Clear filter">
        ✕
      </button>
    </div>
  `,
  styles: [`
    .sac-filter {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .density-compact { gap: 4px; font-size: 13px; }
    .density-comfortable { gap: 8px; font-size: 14px; }
    
    .suggested-filters {
      display: flex;
      gap: 4px;
      margin-right: 8px;
      padding-right: 8px;
      border-right: 1px solid var(--border-color, #ccc);
    }
    .quick-filter {
      padding: 2px 8px;
      border: 1px solid var(--border-color, #ccc);
      border-radius: 12px;
      background: var(--surface, #fff);
      cursor: pointer;
      font-size: 12px;
    }
    .quick-filter:hover { background: var(--hover-bg, #f0f0f0); }
    .quick-filter:focus-visible {
      outline: 2px solid var(--focus-color, #0066cc);
      outline-offset: 2px;
    }
    
    select:focus-visible {
      outline: 2px solid var(--focus-color, #0066cc);
      outline-offset: 2px;
    }
    
    .clear-btn {
      padding: 4px 8px;
      border: none;
      background: transparent;
      cursor: pointer;
    }
    .clear-btn:focus-visible {
      outline: 2px solid var(--focus-color, #0066cc);
      border-radius: 4px;
    }
  `]
})
export class SacFilterAdaptiveComponent implements OnInit, OnDestroy {
  @Input() filterId = '';
  @Input() label = 'Filter';
  @Input() field = '';
  @Input() options: Array<{ value: string; label: string }> = [];
  @Input() value = '';

  @Output() valueChange = new EventEmitter<string>();
  @Output() filterApplied = new EventEmitter<{ field: string; value: string }>();

  labelId = '';
  density: 'compact' | 'comfortable' = 'comfortable';
  suggestedValues: string[] = [];

  private capture!: CaptureHooks;
  private contextUnsubscribe?: () => void;

  ngOnInit(): void {
    this.labelId = `filter-label-${this.filterId || Math.random().toString(36).slice(2)}`;
    
    // Set up capture hooks
    this.capture = createCaptureHooks({
      componentType: 'filter',
      componentId: this.filterId || `filter-${this.field}`,
      defaultMetadata: { field: this.field },
    });

    // Subscribe to context changes
    this.contextUnsubscribe = contextProvider.subscribe((ctx) => {
      this.onContextChange(ctx);
    });

    // Load suggested values from capture history
    this.loadSuggestedValues();
  }

  ngOnDestroy(): void {
    this.contextUnsubscribe?.();
  }

  private onContextChange(ctx: AdaptiveContext): void {
    // Adapt density based on device and user expertise
    if (ctx.device.type === 'mobile') {
      this.density = 'comfortable';
    } else if (ctx.user.role.expertiseLevel === 'expert') {
      this.density = 'compact';
    } else {
      this.density = 'comfortable';
    }
  }

  private loadSuggestedValues(): void {
    // In real impl, this would query the capture service for patterns
    // For now, just demonstrate the concept
    this.suggestedValues = [];
  }

  onFilterChange(event: Event): void {
    const select = event.target as HTMLSelectElement;
    const newValue = select.value;
    
    // Capture the interaction
    this.capture.captureFilter(this.field, newValue, {
      previousValue: this.value,
      optionCount: this.options.length,
    });

    this.value = newValue;
    this.valueChange.emit(newValue);
    this.filterApplied.emit({ field: this.field, value: newValue });
  }

  selectValue(value: string): void {
    this.capture.captureFilter(this.field, value, {
      source: 'suggested',
      previousValue: this.value,
    });

    this.value = value;
    this.valueChange.emit(value);
    this.filterApplied.emit({ field: this.field, value });
  }

  clearFilter(): void {
    this.capture.captureFilter(this.field, '', {
      action: 'clear',
      previousValue: this.value,
    });

    this.value = '';
    this.valueChange.emit('');
    this.filterApplied.emit({ field: this.field, value: '' });
  }
}

