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
import '@ui5/webcomponents/dist/Calendar.js';
import {
  default as Calendar,
  CalendarSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/Calendar.js';
@ProxyInputs([
  'primaryCalendarType',
  'secondaryCalendarType',
  'formatPattern',
  'displayFormat',
  'valueFormat',
  'minDate',
  'maxDate',
  'calendarWeekNumbering',
  'selectionMode',
  'hideWeekNumbers',
])
@ProxyOutputs(['selection-change: ui5SelectionChange'])
@Component({
  standalone: true,
  selector: 'ui5-calendar',
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
    'selectionMode',
    'hideWeekNumbers',
  ],
  outputs: ['ui5SelectionChange'],
  exportAs: 'ui5Calendar',
})
class CalendarComponent {
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
        Defines the type of selection used in the calendar component.
Accepted property values are:

- `CalendarSelectionMode.Single` - enables a single date selection.(default value)
- `CalendarSelectionMode.Range` - enables selection of a date range.
- `CalendarSelectionMode.Multiple` - enables selection of multiple dates.
        */
  selectionMode!: 'Single' | 'Multiple' | 'Range';
  /**
        Defines the visibility of the week numbers column.

**Note:** For calendars other than Gregorian,
the week numbers are not displayed regardless of what is set.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideWeekNumbers!: boolean;

  /**
     Fired when the selected dates change.

**Note:** If you call `preventDefault()` for this event, the component will not
create instances of `ui5-date` for the newly selected dates. In that case you should do this manually.
    */
  ui5SelectionChange!: EventEmitter<CalendarSelectionChangeEventDetail>;

  private elementRef: ElementRef<Calendar> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Calendar {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CalendarComponent };
