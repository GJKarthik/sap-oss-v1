/**
 * SAC Checkbox Component
 *
 * Angular checkbox component for SAP Analytics Cloud.
 * Selector: sac-checkbox (from mangle widget_category "Checkbox")
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
  selector: 'sac-checkbox',
  template: `
    <label class="sac-checkbox" [class]="cssClass" [style.display]="visible ? 'inline-flex' : 'none'">
      <input
        type="checkbox"
        class="sac-checkbox__input"
        [checked]="checked"
        [disabled]="disabled"
        (change)="handleChange($event)"
      />
      <span class="sac-checkbox__checkmark"></span>
      <span class="sac-checkbox__label" *ngIf="label">{{ label }}</span>
    </label>
  `,
  styles: [`
    .sac-checkbox {
      display: inline-flex;
      align-items: center;
      cursor: pointer;
      user-select: none;
    }
    .sac-checkbox__input {
      position: absolute;
      opacity: 0;
      cursor: pointer;
      height: 0;
      width: 0;
    }
    .sac-checkbox__checkmark {
      width: 18px;
      height: 18px;
      border: 1px solid #89919a;
      border-radius: 3px;
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.2s ease;
    }
    .sac-checkbox__input:checked ~ .sac-checkbox__checkmark {
      background: #0854a0;
      border-color: #0854a0;
    }
    .sac-checkbox__input:checked ~ .sac-checkbox__checkmark::after {
      content: '';
      width: 5px;
      height: 10px;
      border: solid white;
      border-width: 0 2px 2px 0;
      transform: rotate(45deg);
    }
    .sac-checkbox__input:disabled ~ .sac-checkbox__checkmark {
      background: #f5f6f7;
      cursor: not-allowed;
    }
    .sac-checkbox__label {
      margin-inline-start: 8px;
      font-size: 14px;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacCheckboxComponent),
      multi: true,
    },
  ],
})
export class SacCheckboxComponent implements ControlValueAccessor {
  @Input() label = '';
  @Input() disabled = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onChange = new EventEmitter<boolean>();

  checked = false;
  private onTouched = () => {};
  private onChangeFn = (_: boolean) => {};

  handleChange(event: Event): void {
    const target = event.target as HTMLInputElement;
    this.checked = target.checked;
    this.onChangeFn(this.checked);
    this.onTouched();
    this.onChange.emit(this.checked);
  }

  writeValue(value: boolean): void {
    this.checked = value ?? false;
  }

  registerOnChange(fn: (value: boolean) => void): void {
    this.onChangeFn = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled = isDisabled;
  }
}