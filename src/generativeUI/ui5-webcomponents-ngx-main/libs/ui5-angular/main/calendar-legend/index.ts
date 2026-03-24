import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/CalendarLegend.js';
import CalendarLegend from '@ui5/webcomponents/dist/CalendarLegend.js';
@ProxyInputs([
  'hideToday',
  'hideSelectedDay',
  'hideNonWorkingDay',
  'hideWorkingDay',
])
@Component({
  standalone: true,
  selector: 'ui5-calendar-legend',
  template: '<ng-content></ng-content>',
  inputs: [
    'hideToday',
    'hideSelectedDay',
    'hideNonWorkingDay',
    'hideWorkingDay',
  ],
  exportAs: 'ui5CalendarLegend',
})
class CalendarLegendComponent {
  /**
        Hides the Today item in the legend.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideToday!: boolean;
  /**
        Hides the Selected day item in the legend.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideSelectedDay!: boolean;
  /**
        Hides the Non-Working day item in the legend.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideNonWorkingDay!: boolean;
  /**
        Hides the Working day item in the legend.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideWorkingDay!: boolean;

  private elementRef: ElementRef<CalendarLegend> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): CalendarLegend {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CalendarLegendComponent };
