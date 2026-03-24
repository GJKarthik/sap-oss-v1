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
import '@ui5/webcomponents/dist/OptionCustom.js';
import OptionCustom from '@ui5/webcomponents/dist/OptionCustom.js';
@ProxyInputs(['displayText', 'value', 'tooltip', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-option-custom',
  template: '<ng-content></ng-content>',
  inputs: ['displayText', 'value', 'tooltip', 'selected'],
  exportAs: 'ui5OptionCustom',
})
class OptionCustomComponent {
  /**
        Defines the text, displayed inside the `ui5-select` input filed
when the option gets selected.
        */
  displayText!: string | undefined;
  /**
        Defines the value of the `ui5-select` inside an HTML Form element when this component is selected.
For more information on HTML Form support, see the `name` property of `ui5-select`.
        */
  value!: string | undefined;
  /**
        Defines the tooltip of the option.
        */
  tooltip!: string | undefined;
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<OptionCustom> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): OptionCustom {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { OptionCustomComponent };
