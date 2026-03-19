// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Filter Components — P2-002 Expansion
 *
 * Accessible filter widgets for SAC data binding:
 * - sac-filter-dropdown: Single/multi-select dropdown
 * - sac-filter-checkbox: Checkbox list filter
 * - sac-filter-date-range: Date range picker
 *
 * WCAG AA Compliance:
 * - Proper labeling with aria-label/aria-labelledby
 * - Keyboard navigation support
 * - Focus visible indicators
 * - Screen reader announcements for selection changes
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
  HostBinding,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import type { SacDimensionFilter, SacDimensionFilterValue } from '../types/sac-widget-schema';

export interface FilterOption {
  value: string;
  label: string;
  selected?: boolean;
}

export interface FilterChangeEvent {
  dimension: string;
  value: SacDimensionFilterValue;
  filterType: 'SingleValue' | 'MultipleValue';
}

// =============================================================================
// Filter Dropdown Component
// =============================================================================

@Component({
  selector: 'sac-filter-dropdown',
  standalone: true,
  imports: [CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-filter sac-filter--dropdown"
         [class.sac-filter--disabled]="disabled"
         role="group"
         [attr.aria-labelledby]="labelId">
      <label [id]="labelId" class="sac-filter__label">{{ label }}</label>
      <select
        class="sac-filter__select"
        [attr.aria-label]="ariaLabel || label"
        [attr.aria-describedby]="ariaDescription ? descId : null"
        [disabled]="disabled"
        [multiple]="multiple"
        [(ngModel)]="selectedValue"
        (ngModelChange)="onSelectionChange($event)">
        <option *ngIf="!multiple && placeholder" value="" disabled>{{ placeholder }}</option>
        <option *ngFor="let opt of options" [value]="opt.value">{{ opt.label }}</option>
      </select>
      <span *ngIf="ariaDescription" [id]="descId" class="sr-only">{{ ariaDescription }}</span>
      <!-- Live region for screen reader announcements -->
      <span role="status" aria-live="polite" class="sr-only">{{ announcement }}</span>
    </div>
  `,
  styles: [`
    .sac-filter { display: flex; flex-direction: column; gap: 4px; }
    .sac-filter__label {
      font-size: 12px; font-weight: 600; color: var(--sapTextColor, #333);
      text-transform: uppercase; letter-spacing: 0.5px;
    }
    .sac-filter__select {
      padding: 8px 12px; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 4px; font-size: 14px; background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #333); cursor: pointer;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .sac-filter__select:hover:not(:disabled) {
      border-color: var(--sapField_Hover_BorderColor, #0854a0);
    }
    .sac-filter__select:focus-visible {
      outline: none; border-color: var(--sapField_Focus_BorderColor, #0854a0);
      box-shadow: 0 0 0 2px var(--sapContent_FocusColor, rgba(8, 84, 160, 0.25));
    }
    .sac-filter__select:disabled {
      opacity: 0.5; cursor: not-allowed; background: var(--sapField_ReadOnly_Background, #f7f7f7);
    }
    .sac-filter--disabled { opacity: 0.6; }
    .sr-only {
      position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
      overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0;
    }
  `],
})
export class SacFilterDropdownComponent {
  @Input() label = 'Filter';
  @Input() dimension = '';
  @Input() options: FilterOption[] = [];
  @Input() multiple = false;
  @Input() placeholder = 'Select...';
  @Input() disabled = false;
  @Input() ariaLabel?: string;
  @Input() ariaDescription?: string;

  @Output() filterChange = new EventEmitter<FilterChangeEvent>();

  selectedValue: string | string[] = '';
  announcement = '';

  get labelId(): string { return `filter-label-${this.dimension}`; }
  get descId(): string { return `filter-desc-${this.dimension}`; }

  onSelectionChange(value: string | string[]): void {
    const filterValue = Array.isArray(value) ? value : value;
    const filterType = this.multiple ? 'MultipleValue' : 'SingleValue';

    this.filterChange.emit({
      dimension: this.dimension,
      value: filterValue,
      filterType,
    });

    // Announce change for screen readers
    if (Array.isArray(value)) {
      this.announcement = `Selected ${value.length} items`;
    } else {
      const label = this.options.find(o => o.value === value)?.label || value;
      this.announcement = `Selected ${label}`;
    }
  }
}

// =============================================================================
// Filter Checkbox Component
// =============================================================================

@Component({
  selector: 'sac-filter-checkbox',
  standalone: true,
  imports: [CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <fieldset class="sac-filter sac-filter--checkbox"
              [class.sac-filter--disabled]="disabled"
              [attr.aria-describedby]="ariaDescription ? descId : null">
      <legend class="sac-filter__label">{{ label }}</legend>
      <div class="sac-filter__options" role="group">
        <label *ngFor="let opt of options; let i = index"
               class="sac-filter__checkbox-label"
               [class.sac-filter__checkbox-label--checked]="opt.selected">
          <input type="checkbox"
                 class="sac-filter__checkbox"
                 [value]="opt.value"
                 [checked]="opt.selected"
                 [disabled]="disabled"
                 (change)="onCheckboxChange(opt, $event)" />
          <span class="sac-filter__checkbox-text">{{ opt.label }}</span>
        </label>
      </div>
      <span *ngIf="ariaDescription" [id]="descId" class="sr-only">{{ ariaDescription }}</span>
      <span role="status" aria-live="polite" class="sr-only">{{ announcement }}</span>
    </fieldset>
  `,
  styles: [`
    .sac-filter--checkbox { border: none; padding: 0; margin: 0; }
    .sac-filter--checkbox .sac-filter__label {
      font-size: 12px; font-weight: 600; color: var(--sapTextColor, #333);
      text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 8px;
    }
    .sac-filter__options { display: flex; flex-direction: column; gap: 8px; }
    .sac-filter__checkbox-label {
      display: flex; align-items: center; gap: 8px; cursor: pointer;
      padding: 4px 8px; border-radius: 4px; transition: background 0.15s;
    }
    .sac-filter__checkbox-label:hover:not(.sac-filter--disabled *) {
      background: var(--sapList_Hover_Background, rgba(0,0,0,0.04));
    }
    .sac-filter__checkbox {
      width: 18px; height: 18px; cursor: pointer;
      accent-color: var(--sapBrandColor, #0854a0);
    }
    .sac-filter__checkbox:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0854a0);
      outline-offset: 2px;
    }
    .sac-filter__checkbox-text { font-size: 14px; color: var(--sapTextColor, #333); }
    .sac-filter--disabled { opacity: 0.6; }
    .sac-filter--disabled * { cursor: not-allowed; }
  `],
})
export class SacFilterCheckboxComponent {
  @Input() label = 'Filter';
  @Input() dimension = '';
  @Input() options: FilterOption[] = [];
  @Input() disabled = false;
  @Input() ariaDescription?: string;

  @Output() filterChange = new EventEmitter<FilterChangeEvent>();

  announcement = '';
  get descId(): string { return `filter-desc-${this.dimension}`; }

  onCheckboxChange(option: FilterOption, event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    option.selected = checked;

    const selectedValues = this.options
      .filter(o => o.selected)
      .map(o => o.value);

    this.filterChange.emit({
      dimension: this.dimension,
      value: selectedValues,
      filterType: 'MultipleValue',
    });

    this.announcement = checked
      ? `${option.label} selected, ${selectedValues.length} total`
      : `${option.label} deselected, ${selectedValues.length} total`;
  }
}

