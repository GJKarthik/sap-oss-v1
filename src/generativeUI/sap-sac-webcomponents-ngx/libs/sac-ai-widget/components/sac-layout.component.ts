// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Layout Components — P2-002 Expansion
 *
 * Accessible layout containers for SAC widget composition:
 * - sac-flex-container: Flexbox layout
 * - sac-grid-container: CSS Grid layout
 *
 * WCAG AA Compliance:
 * - Proper semantic structure
 * - Logical reading order preserved
 * - Responsive breakpoints for accessibility
 * - Touch targets meet minimum size requirements
 * - Supports zoom to 400%
 */

import {
  Component,
  Input,
  ChangeDetectionStrategy,
  HostBinding,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type {
  SacLayoutConfig,
  SacGridConfig,
  SacLayoutDirection,
  SacLayoutJustify,
  SacLayoutAlign,
} from '../types/sac-widget-schema';

// =============================================================================
// Flex Container Component
// =============================================================================

@Component({
  selector: 'sac-flex-container',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-flex"
         [class.sac-flex--row]="direction === 'row'"
         [class.sac-flex--column]="direction === 'column'"
         [class.sac-flex--wrap]="wrap"
         [style.justify-content]="justifyMap[justify]"
         [style.align-items]="alignMap[align]"
         [style.gap.px]="gap * 8"
         [attr.role]="role"
         [attr.aria-label]="ariaLabel">
      <ng-content></ng-content>
    </div>
  `,
  styles: [`
    :host { display: block; }
    .sac-flex { display: flex; }
    .sac-flex--row { flex-direction: row; }
    .sac-flex--column { flex-direction: column; }
    .sac-flex--wrap { flex-wrap: wrap; }

    /* Responsive: stack on small screens */
    @media (max-width: 599px) {
      .sac-flex--row { flex-direction: column; }
    }
  `],
})
export class SacFlexContainerComponent {
  @Input() direction: SacLayoutDirection = 'row';
  @Input() justify: SacLayoutJustify = 'start';
  @Input() align: SacLayoutAlign = 'stretch';
  @Input() gap = 2; // 8px grid units
  @Input() wrap = false;
  @Input() role?: string;
  @Input() ariaLabel?: string;

  readonly justifyMap: Record<SacLayoutJustify, string> = {
    'start': 'flex-start',
    'center': 'center',
    'end': 'flex-end',
    'space-between': 'space-between',
    'space-around': 'space-around',
  };

  readonly alignMap: Record<SacLayoutAlign, string> = {
    'start': 'flex-start',
    'center': 'center',
    'end': 'flex-end',
    'stretch': 'stretch',
  };
}

// =============================================================================
// Grid Container Component
// =============================================================================

@Component({
  selector: 'sac-grid-container',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-grid"
         [style.grid-template-columns]="gridColumns"
         [style.grid-template-rows]="gridRows"
         [style.gap.px]="gap * 8"
         [attr.role]="role"
         [attr.aria-label]="ariaLabel">
      <ng-content></ng-content>
    </div>
  `,
  styles: [`
    :host { display: block; }
    .sac-grid { display: grid; }

    /* Responsive grid: fewer columns on smaller screens */
    @media (max-width: 1439px) {
      :host[data-responsive="true"] .sac-grid {
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)) !important;
      }
    }
    @media (max-width: 1023px) {
      :host[data-responsive="true"] .sac-grid {
        grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)) !important;
      }
    }
    @media (max-width: 599px) {
      :host[data-responsive="true"] .sac-grid {
        grid-template-columns: 1fr !important;
      }
    }
  `],
})
export class SacGridContainerComponent {
  @Input() columns = 12;
  @Input() rows?: number;
  @Input() gap = 2; // 8px grid units
  @Input() minColumnWidth?: number; // px
  @Input() role?: string;
  @Input() ariaLabel?: string;

  @HostBinding('attr.data-responsive')
  @Input() responsive = true;

  get gridColumns(): string {
    if (this.minColumnWidth) {
      return `repeat(auto-fit, minmax(${this.minColumnWidth}px, 1fr))`;
    }
    return `repeat(${this.columns}, 1fr)`;
  }

  get gridRows(): string | undefined {
    return this.rows ? `repeat(${this.rows}, auto)` : undefined;
  }
}

// =============================================================================
// Grid Item Component
// =============================================================================

@Component({
  selector: 'sac-grid-item',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<ng-content></ng-content>`,
  styles: [`
    :host { display: block; }
  `],
})
export class SacGridItemComponent {
  @HostBinding('style.grid-column')
  get gridColumnStyle(): string | undefined {
    return this.colSpan ? `span ${this.colSpan}` : undefined;
  }

  @HostBinding('style.grid-row')
  get gridRowStyle(): string | undefined {
    return this.rowSpan ? `span ${this.rowSpan}` : undefined;
  }

  @Input() colSpan?: number;
  @Input() rowSpan?: number;
}

