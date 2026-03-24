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
import '@ui5/webcomponents/dist/RatingIndicator.js';
import RatingIndicator from '@ui5/webcomponents/dist/RatingIndicator.js';
@ProxyInputs([
  'value',
  'max',
  'size',
  'disabled',
  'readonly',
  'accessibleName',
  'accessibleNameRef',
  'required',
  'tooltip',
])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-rating-indicator',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'max',
    'size',
    'disabled',
    'readonly',
    'accessibleName',
    'accessibleNameRef',
    'required',
    'tooltip',
  ],
  outputs: ['ui5Change'],
  exportAs: 'ui5RatingIndicator',
})
class RatingIndicatorComponent {
  /**
        The indicated value of the rating.

**Note:** If you set a number which is not round, it would be shown as follows:

- 1.0 - 1.2 -> 1
- 1.3 - 1.7 -> 1.5
- 1.8 - 1.9 -> 2
        */
  value!: number;
  /**
        The number of displayed rating symbols.
        */
  max!: number;
  /**
        Defines the size of the component.
        */
  size!: 'S' | 'M' | 'L';
  /**
        Defines whether the component is disabled.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines whether the component is read-only.

**Note:** A read-only component is not editable,
but still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines the tooltip of the component.
        */
  tooltip!: string | undefined;

  /**
     The event is fired when the value changes.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<RatingIndicator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): RatingIndicator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { RatingIndicatorComponent };
