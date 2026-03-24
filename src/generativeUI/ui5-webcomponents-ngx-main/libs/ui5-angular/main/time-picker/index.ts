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
import { GenericControlValueAccessor } from '@ui5/webcomponents-ngx/generic-cva';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TimePicker.js';
import {
  default as TimePicker,
  TimePickerChangeEventDetail,
  TimePickerInputEventDetail,
} from '@ui5/webcomponents/dist/TimePicker.js';
@ProxyInputs([
  'value',
  'name',
  'valueState',
  'disabled',
  'readonly',
  'placeholder',
  'formatPattern',
  'open',
  'required',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'open: ui5Open',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-time-picker',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'name',
    'valueState',
    'disabled',
    'readonly',
    'placeholder',
    'formatPattern',
    'open',
    'required',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
  ],
  outputs: ['ui5Change', 'ui5Input', 'ui5Open', 'ui5Close'],
  exportAs: 'ui5TimePicker',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class TimePickerComponent {
  /**
        Defines a formatted time value.
        */
  value!: string;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines the disabled state of the comonent.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the readonly state of the comonent.
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
        Determines the format, displayed in the input field.

Example:
HH:mm:ss -> 11:42:35
hh:mm:ss a -> 2:23:15 PM
mm:ss -> 12:04 (only minutes and seconds)
        */
  formatPattern!: string | undefined;
  /**
        Defines the open or closed state of the popover.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines the aria-label attribute for the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id (or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the input.
        */
  accessibleDescriptionRef!: string | undefined;

  /**
     Fired when the input operation has finished by clicking the "OK" button or
when the text in the input field has changed and the focus leaves the input field.
    */
  ui5Change!: EventEmitter<TimePickerChangeEventDetail>;
  /**
     Fired when the value of the `ui5-time-picker` is changed at each key stroke.
    */
  ui5Input!: EventEmitter<TimePickerInputEventDetail>;
  /**
     Fired after the value-help dialog of the component is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired after the value-help dialog of the component is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<TimePicker> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): TimePicker {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.value = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.value;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { TimePickerComponent };
