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
import '@ui5/webcomponents/dist/SegmentedButtonItem.js';
import SegmentedButtonItem from '@ui5/webcomponents/dist/SegmentedButtonItem.js';
@ProxyInputs([
  'disabled',
  'selected',
  'tooltip',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'icon',
])
@Component({
  standalone: true,
  selector: 'ui5-segmented-button-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'disabled',
    'selected',
    'tooltip',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'icon',
  ],
  exportAs: 'ui5SegmentedButtonItem',
})
class SegmentedButtonItemComponent {
  /**
        Defines whether the component is disabled.
A disabled component can't be selected or
focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Determines whether the component is displayed as selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines the tooltip of the component.

**Note:** A tooltip attribute should be provided for icon-only buttons, in order to represent their exact meaning/function.
        */
  tooltip!: string | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines the IDs of the HTML Elements that describe the component.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Defines the icon, displayed as graphical element within the component.
The SAP-icons font provides numerous options.

Example:
See all the available icons within the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;

  private elementRef: ElementRef<SegmentedButtonItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SegmentedButtonItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SegmentedButtonItemComponent };
