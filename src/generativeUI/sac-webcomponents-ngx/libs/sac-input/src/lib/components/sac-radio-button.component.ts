/**
 * SAC Radio Button Component
 *
 * Angular radio button component for SAP Analytics Cloud.
 * Selector: sac-radio-button (from mangle widget_category "RadioButton")
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

export interface RadioOption {
  key: string;
  text: string;
  disabled?: boolean;
}

@Component({
  selector: 'sac-radio-button',
  template: `
    <div class="sac-radio-group" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <label class="sac-radio-group__label" *ngIf="groupLabel">{{ groupLabel }}</label>
      <div class="sac-radio-group__options" [class.sac-radio-group__options--horizontal]="horizontal">
        <label
          *ngFor="let option of options"
          class="sac-radio"
          [class.sac-radio--disabled]="option.disabled || disabled">
          <input
            type="radio"
            class="sac-radio__input"
            [name]="name"
            [value]="option.key"
            [checked]="value === option.key"
            [disabled]="option.disabled || disabled"
            (change)="handleChange(option.key)"
          />
          <span class="sac-radio__circle"></span>
          <span class="sac-radio__text">{{ option.text }}</span>
        </label>
      </div>
    </div>
  `,
  styles: [`
    .sac-radio-group__label {
      display: block;
      margin-bottom: 8px;
      font-size: 12px;
      color: #32363a;
    }
    .sac-radio-group__options {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .sac-radio-group__options--horizontal {
      flex-direction: row;
      gap: 16px;
    }
    .sac-radio {
      display: inline-flex;
      align-items: center;
      cursor: pointer;
      user-select: none;
    }
    .sac-radio--disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .sac-radio__input {
      position: absolute;
      opacity: 0;
      cursor: pointer;
    }
    .sac-radio__circle {
      width: 18px;
      height: 18px;
      border: 1px solid #89919a;
      border-radius: 50%;
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.2s ease;
    }
    .sac-radio__input:checked ~ .sac-radio__circle {
      border-color: #0854a0;
    }
    .sac-radio__input:checked ~ .sac-radio__circle::after {
      content: '';
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: #0854a0;
    }
    .sac-radio__text {
      margin-inline-start: 8px;
      font-size: 14px;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacRadioButtonComponent),
      multi: true,
    },
  ],
})
export class SacRadioButtonComponent implements ControlValueAccessor {
  @Input() options: RadioOption[] = [];
  @Input() name = `radio_${Date.now()}`;
  @Input() groupLabel = '';
  @Input() horizontal = false;
  @Input() disabled = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onChange = new EventEmitter<string>();

  value = '';
  private onTouched = () => {};
  private onChangeFn = (_: string) => {};

  handleChange(key: string): void {
    this.value = key;
    this.onChangeFn(this.value);
    this.onTouched();
    this.onChange.emit(this.value);
  }

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