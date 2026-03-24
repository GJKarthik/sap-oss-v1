import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/StepInput.js';
import {
  default as StepInput,
  StepInputValueStateChangeEventDetail,
} from '@ui5/webcomponents/dist/StepInput.js';
@ProxyInputs([
  'value',
  'min',
  'max',
  'step',
  'valueState',
  'required',
  'disabled',
  'readonly',
  'placeholder',
  'name',
  'valuePrecision',
  'accessibleName',
  'accessibleNameRef',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'value-state-change: ui5ValueStateChange',
])
@Component({
  standalone: true,
  selector: 'ui5-step-input',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'min',
    'max',
    'step',
    'valueState',
    'required',
    'disabled',
    'readonly',
    'placeholder',
    'name',
    'valuePrecision',
    'accessibleName',
    'accessibleNameRef',
  ],
  outputs: ['ui5Change', 'ui5Input', 'ui5ValueStateChange'],
  exportAs: 'ui5StepInput',
})
class StepInputComponent {
  /**
        Defines a value of the component.
        */
  value!: number;
  /**
        Defines a minimum value of the component.
        */
  min!: number | undefined;
  /**
        Defines a maximum value of the component.
        */
  max!: number | undefined;
  /**
        Defines a step of increasing/decreasing the value of the component.
        */
  step!: number;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Determines whether the component is displayed as disabled.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Determines whether the component is displayed as read-only.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines a short hint, intended to aid the user with data entry when the
component has no value.

**Note:** When no placeholder is set, the format pattern is displayed as a placeholder.
Passing an empty string as the value of this property will make the component appear empty - without placeholder or format pattern.
        */
  placeholder!: string | undefined;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Determines the number of digits after the decimal point of the component.
        */
  valuePrecision!: number;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;

  /**
     Fired when the input operation has finished by pressing Enter or on focusout.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the value of the component changes at each keystroke.
    */
  ui5Input!: EventEmitter<void>;
  /**
     Fired before the value state of the component is updated internally.
The event is preventable, meaning that if it's default action is
prevented, the component will not update the value state.
    */
  ui5ValueStateChange!: EventEmitter<StepInputValueStateChangeEventDetail>;

  private elementRef: ElementRef<StepInput> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): StepInput {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { StepInputComponent };
