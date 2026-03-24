import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/CalendarDate.js';
import CalendarDate from '@ui5/webcomponents/dist/CalendarDate.js';
@ProxyInputs(['value'])
@Component({
  standalone: true,
  selector: 'ui5-date',
  template: '<ng-content></ng-content>',
  inputs: ['value'],
  exportAs: 'ui5Date',
})
class CalendarDateComponent {
  /**
        The date formatted according to the `formatPattern` property
of the `ui5-calendar` that hosts the component.
        */
  value!: string;

  private elementRef: ElementRef<CalendarDate> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): CalendarDate {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CalendarDateComponent };
