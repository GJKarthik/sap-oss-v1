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
import '@ui5/webcomponents/dist/SplitButton.js';
import {
  default as SplitButton,
  SplitButtonAccessibilityAttributes,
} from '@ui5/webcomponents/dist/SplitButton.js';
@ProxyInputs([
  'icon',
  'activeArrowButton',
  'design',
  'disabled',
  'accessibleName',
  'accessibilityAttributes',
])
@ProxyOutputs(['click: ui5Click', 'arrow-click: ui5ArrowClick'])
@Component({
  standalone: true,
  selector: 'ui5-split-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'icon',
    'activeArrowButton',
    'design',
    'disabled',
    'accessibleName',
    'accessibilityAttributes',
  ],
  outputs: ['ui5Click', 'ui5ArrowClick'],
  exportAs: 'ui5SplitButton',
})
class SplitButtonComponent {
  /**
        Defines the icon to be displayed as graphical element within the component.
The SAP-icons font provides numerous options.

Example:

See all available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines whether the arrow button should have the active state styles or not.
        */
  @InputDecorator({ transform: booleanAttribute })
  activeArrowButton!: boolean;
  /**
        Defines the component design.
        */
  design!:
    | 'Default'
    | 'Positive'
    | 'Negative'
    | 'Transparent'
    | 'Emphasized'
    | 'Attention';
  /**
        Defines whether the component is disabled.
A disabled component can't be pressed or
focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The `accessibilityAttributes` property accepts an object with the following optional fields:

- **root**: Attributes that will be applied to the main (text) button.
  - **hasPopup**: Indicates the presence and type of popup triggered by the button.
    Accepts string values: `"dialog"`, `"grid"`, `"listbox"`, `"menu"`, or `"tree"`.
  - **roleDescription**: Provides a human-readable description for the role of the button.
    Accepts any string value.
  - **title**: Specifies a tooltip or description for screen readers.
    Accepts any string value.
	- **ariaKeyShortcuts**: Defines keyboard shortcuts that activate or give focus to the button.

- **arrowButton**: Attributes applied specifically to the arrow (split) button.
  - **hasPopup**: Indicates the presence and type of popup triggered by the arrow button.
    Accepts string values: `"dialog"`, `"grid"`, `"listbox"`, `"menu"`, or `"tree"`.
  - **expanded**: Indicates whether the popup triggered by the arrow button is currently expanded.
    Accepts boolean values: `true` or `false`.
        */
  accessibilityAttributes!: SplitButtonAccessibilityAttributes;

  /**
     Fired when the user clicks on the default action.
    */
  ui5Click!: EventEmitter<void>;
  /**
     Fired when the user clicks on the arrow action.
    */
  ui5ArrowClick!: EventEmitter<void>;

  private elementRef: ElementRef<SplitButton> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SplitButton {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SplitButtonComponent };
