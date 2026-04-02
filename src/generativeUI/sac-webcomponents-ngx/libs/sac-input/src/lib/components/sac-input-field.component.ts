/**
 * SAC Input Field Component
 *
 * Angular text input component for SAP Analytics Cloud.
 * Selector: sac-input-field (from mangle widget_category "InputField")
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
  selector: 'sac-input-field',
  template: `
    <div class="sac-input-field" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <label class="sac-input-field__label" *ngIf="label">{{ label }}</label>
      <input
        class="sac-input-field__input"
        [type]="type"
        [value]="value"
        [placeholder]="placeholder"
        [disabled]="disabled"
        [readonly]="readonly"
        [attr.maxlength]="maxLength"
        (input)="handleInput($event)"
        (focus)="handleFocus($event)"
        (blur)="handleBlur($event)"
      />
      <span class="sac-input-field__hint" *ngIf="hint">{{ hint }}</span>
      <span class="sac-input-field__error" *ngIf="error">{{ error }}</span>
    </div>
  `,
  styles: [`
    .sac-input-field {
      display: block;
    }
    .sac-input-field__label {
      display: block;
      margin-bottom: 4px;
      font-size: 12px;
      color: #32363a;
    }
    .sac-input-field__input {
      width: 100%;
      padding: 8px 12px;
      border: 1px solid #89919a;
      border-radius: 4px;
      font-size: 14px;
      box-sizing: border-box;
    }
    .sac-input-field__input:focus {
      outline: none;
      border-color: #0854a0;
    }
    .sac-input-field__input:disabled {
      background: #f5f6f7;
      cursor: not-allowed;
    }
    .sac-input-field__hint {
      display: block;
      margin-top: 4px;
      font-size: 11px;
      color: #6a6d70;
    }
    .sac-input-field__error {
      display: block;
      margin-top: 4px;
      font-size: 11px;
      color: #bb0000;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacInputFieldComponent),
      multi: true,
    },
  ],
})
export class SacInputFieldComponent implements ControlValueAccessor {
  @Input() type: 'text' | 'password' | 'email' | 'number' | 'tel' = 'text';
  @Input() label = '';
  @Input() placeholder = '';
  @Input() hint = '';
  @Input() error = '';
  @Input() disabled = false;
  @Input() readonly = false;
  @Input() visible = true;
  @Input() cssClass = '';
  @Input() maxLength?: number;

  @Output() onChange = new EventEmitter<string>();
  @Output() onFocus = new EventEmitter<FocusEvent>();
  @Output() onBlur = new EventEmitter<FocusEvent>();

  value = '';
  private onTouched = () => {};
  private onChangeFn = (_: string) => {};

  handleInput(event: Event): void {
    const target = event.target as HTMLInputElement;
    this.value = target.value;
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