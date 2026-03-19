/**
 * Adaptive UI Architecture — Filter Capture Directive
 * 
 * Specialized directive for capturing filter interactions.
 */

import {
  Directive,
  Input,
  Output,
  EventEmitter,
  OnInit,
} from '@angular/core';
import { captureService } from '../capture-service';

@Directive({
  selector: '[adaptiveCaptureFilter]',
  standalone: true,
})
export class AdaptiveCaptureFilterDirective implements OnInit {
  @Input('adaptiveCaptureFilter') filterId = '';
  @Input() filterField = '';
  @Input() captureMetadata: Record<string, unknown> = {};

  /** Emits when a filter pattern is detected (for immediate feedback) */
  @Output() patternDetected = new EventEmitter<{
    field: string;
    frequentValues: unknown[];
  }>();

  private componentId: string = '';
  private filterHistory: Array<{ field: string; value: unknown; timestamp: Date }> = [];

  ngOnInit(): void {
    this.componentId = this.filterId || `filter-${Math.random().toString(36).slice(2, 9)}`;
  }

  /** Call this when a filter value is selected */
  captureFilterSelect(field: string, value: unknown): void {
    captureService.capture({
      type: 'filter',
      target: field,
      componentType: 'filter',
      componentId: this.componentId,
      metadata: { 
        field, 
        value, 
        action: 'select',
        ...this.captureMetadata,
      },
    });

    this.trackFilterHistory(field, value);
  }

  /** Call this when a filter is cleared */
  captureFilterClear(field: string): void {
    captureService.capture({
      type: 'filter',
      target: field,
      componentType: 'filter',
      componentId: this.componentId,
      metadata: { 
        field, 
        action: 'clear',
        reset: true,
        ...this.captureMetadata,
      },
    });
  }

  /** Call this when all filters are reset */
  captureFilterReset(): void {
    captureService.capture({
      type: 'filter',
      target: 'all',
      componentType: 'filter',
      componentId: this.componentId,
      metadata: { 
        action: 'reset-all',
        reset: true,
        ...this.captureMetadata,
      },
    });
  }

  /** Call this when a filter preset is applied */
  captureFilterPreset(presetName: string, filters: Record<string, unknown>): void {
    captureService.capture({
      type: 'filter',
      target: 'preset',
      componentType: 'filter',
      componentId: this.componentId,
      metadata: { 
        presetName, 
        filters,
        action: 'apply-preset',
        ...this.captureMetadata,
      },
    });
  }

  /** Call this when a date range filter is used */
  captureDateRangeFilter(
    field: string, 
    startDate: Date | string, 
    endDate: Date | string
  ): void {
    captureService.capture({
      type: 'filter',
      target: field,
      componentType: 'filter',
      componentId: this.componentId,
      metadata: { 
        field,
        startDate: startDate.toString(),
        endDate: endDate.toString(),
        rangeType: this.detectRangeType(startDate, endDate),
        action: 'date-range',
        ...this.captureMetadata,
      },
    });
  }

  private detectRangeType(
    start: Date | string, 
    end: Date | string
  ): string {
    const startDate = new Date(start);
    const endDate = new Date(end);
    const diffDays = Math.round(
      (endDate.getTime() - startDate.getTime()) / (1000 * 60 * 60 * 24)
    );

    if (diffDays <= 1) return 'day';
    if (diffDays <= 7) return 'week';
    if (diffDays <= 31) return 'month';
    if (diffDays <= 92) return 'quarter';
    if (diffDays <= 366) return 'year';
    return 'custom';
  }

  private trackFilterHistory(field: string, value: unknown): void {
    this.filterHistory.push({ field, value, timestamp: new Date() });
    
    // Keep last 50 entries
    if (this.filterHistory.length > 50) {
      this.filterHistory.shift();
    }

    // Detect patterns
    this.detectPatterns(field);
  }

  private detectPatterns(field: string): void {
    const fieldHistory = this.filterHistory.filter(h => h.field === field);
    
    if (fieldHistory.length >= 3) {
      // Find frequently used values
      const valueCounts: Record<string, number> = {};
      for (const h of fieldHistory) {
        const key = JSON.stringify(h.value);
        valueCounts[key] = (valueCounts[key] || 0) + 1;
      }

      const frequentValues = Object.entries(valueCounts)
        .filter(([, count]) => count >= 2)
        .sort((a, b) => b[1] - a[1])
        .map(([value]) => JSON.parse(value));

      if (frequentValues.length > 0) {
        this.patternDetected.emit({ field, frequentValues });
      }
    }
  }
}

