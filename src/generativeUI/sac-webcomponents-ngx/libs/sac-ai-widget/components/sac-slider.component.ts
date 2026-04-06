// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Slider Components — P2-002 Expansion
 *
 * Accessible slider/range widgets for SAC data filtering:
 * - sac-slider: Single value slider
 * - sac-range-slider: Dual-thumb range slider
 *
 * WCAG AA Compliance:
 * - role="slider" with aria-valuemin/max/now
 * - Keyboard control (arrow keys, home/end)
 * - Focus visible indicators
 * - Value announcements for screen readers
 * - prefers-reduced-motion support
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
  OnInit,
  inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { SacI18nService } from '@sap-oss/sac-webcomponents-ngx/core';
import { FormsModule } from '@angular/forms';
import type { SacSliderConfig } from '../types/sac-widget-schema';

export interface SliderChangeEvent {
  dimension: string;
  value: number | { low: number; high: number };
}

// =============================================================================
// Single Value Slider Component
// =============================================================================

@Component({
  selector: 'sac-slider',
  standalone: true,
  imports: [CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-slider"
         [class.sac-slider--disabled]="disabled"
         role="group"
         [attr.aria-labelledby]="labelId">
      <div class="sac-slider__header">
        <label [id]="labelId" class="sac-slider__label">{{ displayLabel }}</label>
        <span *ngIf="showValue" class="sac-slider__value" aria-hidden="true">
          {{ formatValue(value) }}
        </span>
      </div>
      <input
        type="range"
        class="sac-slider__input"
        role="slider"
        [attr.aria-label]="ariaLabel || displayLabel"
        [attr.aria-valuemin]="min"
        [attr.aria-valuemax]="max"
        [attr.aria-valuenow]="value"
        [attr.aria-valuetext]="formatValue(value)"
        [min]="min"
        [max]="max"
        [step]="step"
        [disabled]="disabled"
        [(ngModel)]="value"
        (ngModelChange)="onValueChange($event)"
        (keydown)="onKeyDown($event)" />
      <!-- Live region for value changes -->
      <span role="status" aria-live="polite" class="sr-only">{{ announcement }}</span>
    </div>
  `,
  styles: [`
    .sac-slider { display: flex; flex-direction: column; gap: 8px; }
    .sac-slider__header { display: flex; justify-content: space-between; align-items: center; }
    .sac-slider__label {
      font-family: var(--sapFontFamily, 'SAP 72', Arial, sans-serif);
      font-size: 12px; font-weight: 600; color: var(--sapTextColor, #32363a);
      text-transform: uppercase; letter-spacing: 0.5px;
    }
    .sac-slider__value {
      font-size: 14px; font-weight: 600; color: var(--sapBrandColor, #0854a0);
      min-width: 56px; text-align: end;
    }
    .sac-slider__input {
      width: 100%; height: 8px; cursor: pointer;
      accent-color: var(--sapBrandColor, #0854a0);
      border-radius: 4px; background: var(--sapField_BorderColor, #89919a);
    }
    .sac-slider__input::-webkit-slider-thumb {
      width: 20px; height: 20px; border-radius: 50%;
      background: var(--sapBrandColor, #0854a0);
      border: 2px solid var(--sapContent_ContrastFocusColor, #fff);
      cursor: pointer; transition: transform 0.15s;
    }
    .sac-slider__input:hover::-webkit-slider-thumb { transform: scale(1.1); }
    .sac-slider__input:focus-visible {
      outline: none;
    }
    .sac-slider__input:focus-visible::-webkit-slider-thumb {
      box-shadow: 0 0 0 3px var(--sapContent_FocusColor, rgba(0, 112, 242, 0.3));
    }
    .sac-slider__input:focus-visible::-moz-range-thumb {
      box-shadow: 0 0 0 3px var(--sapContent_FocusColor, rgba(0, 112, 242, 0.3));
    }
    .sac-slider__input:disabled {
      opacity: 0.5; cursor: not-allowed;
    }
    .sac-slider--disabled { opacity: 0.6; }
    .sr-only {
      position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
      overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0;
    }
    /* Reduced motion */
    @media (prefers-reduced-motion: reduce) {
      .sac-slider__input::-webkit-slider-thumb { transition: none; }
    }
  `],
})
export class SacSliderComponent implements OnInit {
  private readonly i18n = inject(SacI18nService);

  @Input() label = '';
  @Input() dimension = '';
  @Input() min = 0;
  @Input() max = 100;
  @Input() step = 1;
  @Input() initialValue?: number;
  @Input() showValue = true;
  @Input() format: 'currency' | 'percent' | 'number' = 'number';
  @Input() disabled = false;
  @Input() ariaLabel?: string;

  @Output() sliderChange = new EventEmitter<SliderChangeEvent>();

  value = 0;
  announcement = '';

  get displayLabel(): string {
    return this.label || this.i18n.t('slider.defaultLabel');
  }

  get labelId(): string { return `slider-label-${this.dimension}`; }

  ngOnInit(): void {
    this.value = this.initialValue ?? this.min;
  }

  formatValue(val: number): string {
    switch (this.format) {
      case 'currency': return `$${val.toLocaleString()}`;
      case 'percent': return `${val}%`;
      default: return val.toLocaleString();
    }
  }

  onValueChange(value: number): void {
    this.sliderChange.emit({ dimension: this.dimension, value });
    this.announcement = `${this.displayLabel}: ${this.formatValue(value)}`;
  }

  onKeyDown(event: KeyboardEvent): void {
    // Enhance keyboard support
    const bigStep = (this.max - this.min) / 10;
    switch (event.key) {
      case 'Home':
        this.value = this.min;
        this.onValueChange(this.value);
        event.preventDefault();
        break;
      case 'End':
        this.value = this.max;
        this.onValueChange(this.value);
        event.preventDefault();
        break;
      case 'PageUp':
        this.value = Math.min(this.max, this.value + bigStep);
        this.onValueChange(this.value);
        event.preventDefault();
        break;
      case 'PageDown':
        this.value = Math.max(this.min, this.value - bigStep);
        this.onValueChange(this.value);
        event.preventDefault();
        break;
    }
  }
}

