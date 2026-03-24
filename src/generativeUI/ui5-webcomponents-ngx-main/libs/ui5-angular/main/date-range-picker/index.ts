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
import {
  DatePickerChangeEventDetail,
  DatePickerInputEventDetail,
  DatePickerValueStateChangeEventDetail,
} from '@ui5/webcomponents/dist/DatePicker.js';
import '@ui5/webcomponents/dist/DateRangePicker.js';
import DateRangePicker from '@ui5/webcomponents/dist/DateRangePicker.js';
@ProxyInputs([
  'primaryCalendarType',
  'secondaryCalendarType',
  'formatPattern',
  'displayFormat',
  'valueFormat',
  'minDate',
  'maxDate',
  'calendarWeekNumbering',
  'value',
  'valueState',
  'required',
  'disabled',
  'readonly',
  'placeholder',
  'name',
  'hideWeekNumbers',
  'open',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'delimiter',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'value-state-change: ui5ValueStateChange',
  'open: ui5Open',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-daterange-picker',
  template: '<ng-content></ng-content>',
  inputs: [
    'primaryCalendarType',
    'secondaryCalendarType',
    'formatPattern',
    'displayFormat',
    'valueFormat',
    'minDate',
    'maxDate',
    'calendarWeekNumbering',
    'value',
    'valueState',
    'required',
    'disabled',
    'readonly',
    'placeholder',
    'name',
    'hideWeekNumbers',
    'open',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'delimiter',
  ],
  outputs: [
    'ui5Change',
    'ui5Input',
    'ui5ValueStateChange',
    'ui5Open',
    'ui5Close',
  ],
  exportAs: 'ui5DaterangePicker',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class DateRangePickerComponent {
  /**
        Sets a calendar type used for display.
If not set, the calendar type of the global configuration is used.
        */
  primaryCalendarType!:
    | 'Gregorian'
    | 'Islamic'
    | 'Japanese'
    | 'Buddhist'
    | 'Persian'
    | undefined;
  /**
        Defines the secondary calendar type.
If not set, the calendar will only show the primary calendar type.
        */
  secondaryCalendarType!:
    | 'Gregorian'
    | 'Islamic'
    | 'Japanese'
    | 'Buddhist'
    | 'Persian'
    | undefined;
  /**
        Determines the format, displayed in the input field.
        */
  formatPattern!: string | undefined;
  /**
        Determines the format, displayed in the input field.
        */
  displayFormat!: string | undefined;
  /**
        Determines the format, used for the value attribute.
        */
  valueFormat!: string | undefined;
  /**
        Determines the minimum date available for selection.

**Note:** If the formatPattern property is not set, the minDate value must be provided in the ISO date format (yyyy-MM-dd).
        */
  minDate!: string;
  /**
        Determines the maximum date available for selection.

**Note:** If the formatPattern property is not set, the maxDate value must be provided in the ISO date format (yyyy-MM-dd).
        */
  maxDate!: string;
  /**
        Defines how to calculate calendar weeks and first day of the week.
If not set, the calendar will be displayed according to the currently set global configuration.
        */
  calendarWeekNumbering!:
    | 'Default'
    | 'ISO_8601'
    | 'MiddleEastern'
    | 'WesternTraditional';
  /**
        Defines a formatted date value.
        */
  value!: string;
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
        Defines the visibility of the week numbers column.

**Note:** For calendars other than Gregorian,
the week numbers are not displayed regardless of what is set.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideWeekNumbers!: boolean;
  /**
        Defines the open or closed state of the popover.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the aria-label attribute for the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
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
        Determines the symbol which separates the dates.
If not supplied, the default time interval delimiter for the current locale will be used.
        */
  delimiter!: string;

  /**
     Fired when the input operation has finished by pressing Enter or on focusout.
    */
  ui5Change!: EventEmitter<DatePickerChangeEventDetail>;
  /**
     Fired when the value of the component is changed at each key stroke.
    */
  ui5Input!: EventEmitter<DatePickerInputEventDetail>;
  /**
     Fired before the value state of the component is updated internally.
The event is preventable, meaning that if it's default action is
prevented, the component will not update the value state.
    */
  ui5ValueStateChange!: EventEmitter<DatePickerValueStateChangeEventDetail>;
  /**
     Fired after the component's picker is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired after the component's picker is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<DateRangePicker> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): DateRangePicker {
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
export { DateRangePickerComponent };
