/**
 * SAC Date Picker Component
 *
 * Angular date picker component for SAP Analytics Cloud.
 * Selector: sac-date-picker (from mangle widget_category "DatePicker")
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

@Component({
  selector: 'sac-date-picker',
  template: `
    <div class="sac-date-picker" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <label class="sac-date-picker__label" *ngIf="label">{{ label }}</label>
      <input
        [type]="showTime ? 'datetime-local' : 'date'"
        class="sac-date-picker__input"
        [value]="formattedValue"
        [min]="minDate"
        [max]="maxDate"
        [disabled]="disabled"
        [readonly]="readonly"
        (change)="handleChange($event)"
        (focus)="handleFocus($event)"
        (blur)="handleBlur($event)"
      />
      <span class="sac-date-picker__hint" *ngIf="hint">{{ hint }}</span>
    </div>
  `,
  styles: [`
    .sac-date-picker {
      display: block;
    }
    .sac-date-picker__label {
      display: block;
      margin-bottom: 4px;
      font-size: 12px;
      color: #32363a;
    }
    .sac-date-picker__input {
      width: 100%;
      padding: 8px 12px;
      border: 1px solid #89919a;
      border-radius: 4px;
      font-size: 14px;
      box-sizing: border-box;
    }
    .sac-date-picker__input:focus {
      outline: none;
      border-color: #0854a0;
    }
    .sac-date-picker__input:disabled {
      background: #f5f6f7;
      cursor: not-allowed;
    }
    .sac-date-picker__hint {
      display: block;
      margin-top: 4px;
      font-size: 11px;
      color: #6a6d70;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacDatePickerComponent),
      multi: true,
    },
  ],
})
export class SacDatePickerComponent implements ControlValueAccessor {
  @Input() label = '';
  @Input() hint = '';
  @Input() minDate?: string;
  @Input() maxDate?: string;
  @Input() showTime = false;
  @Input() disabled = false;
  @Input() readonly = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onChange = new EventEmitter<Date | null>();
  @Output() onFocus = new EventEmitter<FocusEvent>();
  @Output() onBlur = new EventEmitter<FocusEvent>();

  value: Date | null = null;
  private onTouched = () => {};
  private onChangeFn = (_: Date | null) => {};

  get formattedValue(): string {
    if (!this.value) return '';
    if (this.showTime) {
      return this.value.toISOString().slice(0, 16);
    }
    return this.value.toISOString().slice(0, 10);
  }

  handleChange(event: Event): void {
    const target = event.target as HTMLInputElement;
    this.value = target.value ? new Date(target.value) : null;
    this.onChangeFn(this.value);
    this.onChange.emit(this.value);
  }

  handleFocus(event: FocusEvent): void {
    this.onFocus.emit(event);
  }

  handleBlur(event: FocusEvent): void {
    this.onTouched();
    this.onBlur.emit(event);
  }

  writeValue(value: Date | string | null): void {
    if (value instanceof Date) {
      this.value = value;
    } else if (typeof value === 'string') {
      this.value = new Date(value);
    } else {
      this.value = null;
    }
  }

  registerOnChange(fn: (value: Date | null) => void): void {
    this.onChangeFn = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled = isDisabled;
  }
}