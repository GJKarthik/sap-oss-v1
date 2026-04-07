/**
 * SAC Dropdown Component
 *
 * Angular dropdown/select component for SAP Analytics Cloud.
 * Selector: sac-dropdown (from mangle widget_category "Dropdown")
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
  forwardRef,
} from '@angular/core';
import { ControlValueAccessor, NG_VALUE_ACCESSOR } from '@angular/forms';

export interface SelectionItem {
  key: string;
  text: string;
  icon?: string;
  disabled?: boolean;
}

@Component({
  selector: 'sac-dropdown',
  template: `
    <div class="sac-dropdown" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <label class="sac-dropdown__label" *ngIf="label">{{ label }}</label>
      <select
        class="sac-dropdown__select"
        [disabled]="disabled"
        [value]="value"
        (change)="handleChange($event)">
        <option *ngIf="placeholder" value="" disabled>{{ placeholder }}</option>
        <option *ngFor="let item of items" [value]="item.key" [disabled]="item.disabled">
          {{ item.text }}
        </option>
      </select>
    </div>
  `,
  styles: [`
    .sac-dropdown {
      display: block;
    }
    .sac-dropdown__label {
      display: block;
      margin-bottom: 4px;
      font-size: 12px;
      color: #32363a;
    }
    .sac-dropdown__select {
      width: 100%;
      padding: 8px 12px;
      border: 1px solid #89919a;
      border-radius: 4px;
      background: white;
      font-size: 14px;
      cursor: pointer;
    }
    .sac-dropdown__select:focus {
      outline: none;
      border-color: #0854a0;
    }
    .sac-dropdown__select:disabled {
      background: #f5f6f7;
      cursor: not-allowed;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacDropdownComponent),
      multi: true,
    },
  ],
})
export class SacDropdownComponent implements ControlValueAccessor {
  @Input() items: SelectionItem[] = [];
  @Input() label = '';
  @Input() placeholder = '';
  @Input() disabled = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onChange = new EventEmitter<string>();

  value = '';
  private onTouched = () => {};
  private onChangeFn = (_: string) => {};

  handleChange(event: Event): void {
    const target = event.target as HTMLSelectElement;
    this.value = target.value;
    this.onChangeFn(this.value);
    this.onTouched();
    this.onChange.emit(this.value);
  }

  // ControlValueAccessor
  writeValue(value: string): void {
    this.value = value ?? '';
  }

  registerOnChange(fn: (value: string) => void): void {
    this.onChangeFn = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled = isDisabled;
  }
}