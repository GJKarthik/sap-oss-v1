import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/DynamicDateRange.js';
import {
  default as DynamicDateRange,
  DynamicDateRangeValue,
} from '@ui5/webcomponents/dist/DynamicDateRange.js';
@ProxyInputs(['value', 'options'])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-dynamic-date-range',
  template: '<ng-content></ng-content>',
  inputs: ['value', 'options'],
  outputs: ['ui5Change'],
  exportAs: 'ui5DynamicDateRange',
})
class DynamicDateRangeComponent {
  /**
        Defines the value object.
        */
  value!: DynamicDateRangeValue | undefined;
  /**
        Defines the options listed as a string, separated by commas and using capital case.
Example: "TODAY, YESTERDAY, DATERANGE"
        */
  options!: string;

  /**
     Fired when the input operation has finished by pressing Enter or on focusout or a value is selected in the popover.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<DynamicDateRange> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): DynamicDateRange {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DynamicDateRangeComponent };
