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
import '@ui5/webcomponents/dist/ProgressIndicator.js';
import ProgressIndicator from '@ui5/webcomponents/dist/ProgressIndicator.js';
@ProxyInputs([
  'accessibleName',
  'hideValue',
  'value',
  'displayValue',
  'valueState',
])
@Component({
  standalone: true,
  selector: 'ui5-progress-indicator',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleName',
    'hideValue',
    'value',
    'displayValue',
    'valueState',
  ],
  exportAs: 'ui5ProgressIndicator',
})
class ProgressIndicatorComponent {
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines whether the component value is shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideValue!: boolean;
  /**
        Specifies the numerical value in percent for the length of the component.

**Note:**
If a value greater than 100 is provided, the percentValue is set to 100. In other cases of invalid value, percentValue is set to its default of 0.
        */
  value!: number;
  /**
        Specifies the text value to be displayed in the bar.

**Note:**

- If there is no value provided or the value is empty, the default percentage value is shown.
- If `hideValue` property is `true` both the `displayValue` and `value` property values are not shown.
        */
  displayValue!: string | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';

  private elementRef: ElementRef<ProgressIndicator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ProgressIndicator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ProgressIndicatorComponent };
