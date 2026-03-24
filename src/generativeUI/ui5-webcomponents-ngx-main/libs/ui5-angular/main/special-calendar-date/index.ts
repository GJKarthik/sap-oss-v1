import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/SpecialCalendarDate.js';
import SpecialCalendarDate from '@ui5/webcomponents/dist/SpecialCalendarDate.js';
@ProxyInputs(['value', 'type'])
@Component({
  standalone: true,
  selector: 'ui5-special-date',
  template: '<ng-content></ng-content>',
  inputs: ['value', 'type'],
  exportAs: 'ui5SpecialDate',
})
class SpecialCalendarDateComponent {
  /**
        The date formatted according to the `formatPattern` property
of the `ui5-calendar` that hosts the component.
        */
  value!: string;
  /**
        Defines the type of the special date.
        */
  type!:
    | 'None'
    | 'Working'
    | 'NonWorking'
    | 'Type01'
    | 'Type02'
    | 'Type03'
    | 'Type04'
    | 'Type05'
    | 'Type06'
    | 'Type07'
    | 'Type08'
    | 'Type09'
    | 'Type10'
    | 'Type11'
    | 'Type12'
    | 'Type13'
    | 'Type14'
    | 'Type15'
    | 'Type16'
    | 'Type17'
    | 'Type18'
    | 'Type19'
    | 'Type20';

  private elementRef: ElementRef<SpecialCalendarDate> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SpecialCalendarDate {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SpecialCalendarDateComponent };
