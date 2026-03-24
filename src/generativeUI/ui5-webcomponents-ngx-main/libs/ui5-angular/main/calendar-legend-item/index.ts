import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/CalendarLegendItem.js';
import CalendarLegendItem from '@ui5/webcomponents/dist/CalendarLegendItem.js';
@ProxyInputs(['text', 'type'])
@Component({
  standalone: true,
  selector: 'ui5-calendar-legend-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'type'],
  exportAs: 'ui5CalendarLegendItem',
})
class CalendarLegendItemComponent {
  /**
        Defines the text content of the Calendar Legend Item.
        */
  text!: string | undefined;
  /**
        Defines the type of the Calendar Legend Item.
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

  private elementRef: ElementRef<CalendarLegendItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): CalendarLegendItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CalendarLegendItemComponent };
