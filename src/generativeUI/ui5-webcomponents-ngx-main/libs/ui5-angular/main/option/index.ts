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
import '@ui5/webcomponents/dist/Option.js';
import Option from '@ui5/webcomponents/dist/Option.js';
@ProxyInputs(['value', 'icon', 'additionalText', 'tooltip', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-option',
  template: '<ng-content></ng-content>',
  inputs: ['value', 'icon', 'additionalText', 'tooltip', 'selected'],
  exportAs: 'ui5Option',
})
class OptionComponent {
  /**
        Defines the value of the `ui5-select` inside an HTML Form element when this component is selected.
For more information on HTML Form support, see the `name` property of `ui5-select`.
        */
  value!: string | undefined;
  /**
        Defines the `icon` source URI.

**Note:**
SAP-icons font provides numerous built-in icons. To find all the available icons, see the
[Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines the `additionalText`, displayed in the end of the option.
        */
  additionalText!: string | undefined;
  /**
        Defines the tooltip of the option.
        */
  tooltip!: string | undefined;
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<Option> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Option {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { OptionComponent };
