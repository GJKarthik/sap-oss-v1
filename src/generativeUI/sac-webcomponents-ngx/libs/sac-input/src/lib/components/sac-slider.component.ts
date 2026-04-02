/**
 * SAC Slider Component
 *
 * Angular slider/range component for SAP Analytics Cloud.
 * Selector: sac-slider (from mangle widget_category "Slider")
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
  selector: 'sac-slider',
  template: `
    <div class="sac-slider" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <label class="sac-slider__label" *ngIf="label">{{ label }}</label>
      <div class="sac-slider__container">
        <span class="sac-slider__min">{{ min }}</span>
        <input
          type="range"
          class="sac-slider__input"
          [min]="min"
          [max]="max"
          [step]="step"
          [value]="value"
          [disabled]="disabled"
          (input)="handleInput($event)"
          (change)="handleChange($event)"
        />
        <span class="sac-slider__max">{{ max }}</span>
      </div>
      <div class="sac-slider__value" *ngIf="showValue">{{ value }}</div>
    </div>
  `,
  styles: [`
    .sac-slider {
      display: block;
    }
    .sac-slider__label {
      display: block;
      margin-bottom: 8px;
      font-size: 12px;
      color: #32363a;
    }
    .sac-slider__container {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .sac-slider__input {
      flex: 1;
      height: 4px;
      appearance: none;
      background: #e5e5e5;
      border-radius: 2px;
      cursor: pointer;
    }
    .sac-slider__input::-webkit-slider-thumb {
      appearance: none;
      width: 18px;
      height: 18px;
      background: #0854a0;
      border-radius: 50%;
      cursor: pointer;
    }
    .sac-slider__input::-moz-range-thumb {
      width: 18px;
      height: 18px;
      background: #0854a0;
      border-radius: 50%;
      cursor: pointer;
      border: none;
    }
    .sac-slider__input:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .sac-slider__min,
    .sac-slider__max {
      font-size: 12px;
      color: #6a6d70;
      min-width: 30px;
    }
    .sac-slider__max {
      text-align: right;
    }
    .sac-slider__value {
      text-align: center;
      margin-top: 8px;
      font-size: 14px;
      font-weight: 600;
      color: #0854a0;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [
    {
      provide: NG_VALUE_ACCESSOR,
      useExisting: forwardRef(() => SacSliderComponent),
      multi: true,
    },
  ],
})
export class SacSliderComponent implements ControlValueAccessor {
  @Input() label = '';
  @Input() min = 0;
  @Input() max = 100;
  @Input() step = 1;
  @Input() showValue = true;
  @Input() disabled = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onChange = new EventEmitter<number>();
  @Output() onInput = new EventEmitter<number>();

  value = 0;
  private onTouched = () => {};
  private onChangeFn = (_: number) => {};

  handleInput(event: Event): void {
    const target = event.target as HTMLInputElement;
    this.value = Number(target.value);
    this.onInput.emit(this.value);
  }

  handleChange(event: Event): void {
    const target = event.target as HTMLInputElement;
    this.value = Number(target.value);
    this.onChangeFn(this.value);
    this.onTouched();
    this.onChange.emit(this.value);
  }

  writeValue(value: number): void {
    this.value = value ?? this.min;
  }

  registerOnChange(fn: (value: number) => void): void {
    this.onChangeFn = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled = isDisabled;
  }
}