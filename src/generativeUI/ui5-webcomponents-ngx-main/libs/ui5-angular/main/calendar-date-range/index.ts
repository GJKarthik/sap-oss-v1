import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/CalendarDateRange.js';
import CalendarDateRange from '@ui5/webcomponents/dist/CalendarDateRange.js';
@ProxyInputs(['startValue', 'endValue'])
@Component({
  standalone: true,
  selector: 'ui5-date-range',
  template: '<ng-content></ng-content>',
  inputs: ['startValue', 'endValue'],
  exportAs: 'ui5DateRange',
})
class CalendarDateRangeComponent {
  /**
        Start of date range formatted according to the `formatPattern` property
of the `ui5-calendar` that hosts the component.
        */
  startValue!: string;
  /**
        End of date range formatted according to the `formatPattern` property
of the `ui5-calendar` that hosts the component.
        */
  endValue!: string;

  private elementRef: ElementRef<CalendarDateRange> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): CalendarDateRange {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CalendarDateRangeComponent };
