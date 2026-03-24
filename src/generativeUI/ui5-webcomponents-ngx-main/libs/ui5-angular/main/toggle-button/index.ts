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
import {
  ButtonAccessibilityAttributes,
  ButtonClickEventDetail,
} from '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/ToggleButton.js';
import ToggleButton from '@ui5/webcomponents/dist/ToggleButton.js';
@ProxyInputs([
  'design',
  'disabled',
  'icon',
  'endIcon',
  'submits',
  'tooltip',
  'accessibleName',
  'accessibleNameRef',
  'accessibilityAttributes',
  'accessibleDescription',
  'type',
  'accessibleRole',
  'loading',
  'loadingDelay',
  'pressed',
])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-toggle-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'design',
    'disabled',
    'icon',
    'endIcon',
    'submits',
    'tooltip',
    'accessibleName',
    'accessibleNameRef',
    'accessibilityAttributes',
    'accessibleDescription',
    'type',
    'accessibleRole',
    'loading',
    'loadingDelay',
    'pressed',
  ],
  outputs: ['ui5Click'],
  exportAs: 'ui5ToggleButton',
})
class ToggleButtonComponent {
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
        Defines the icon, displayed as graphical element within the component.
The SAP-icons font provides numerous options.

Example:
See all the available icons within the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines the icon, displayed as graphical element within the component after the button text.

**Note:** It is highly recommended to use `endIcon` property only together with `icon` and/or `text` properties.
Usage of `endIcon` only should be avoided.

The SAP-icons font provides numerous options.

Example:
See all the available icons within the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  endIcon!: string | undefined;
  /**
        When set to `true`, the component will
automatically submit the nearest HTML form element on `press`.

**Note:** This property is only applicable within the context of an HTML Form element.`
        */
  @InputDecorator({ transform: booleanAttribute })
  submits!: boolean;
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
        Defines the additional accessibility attributes that will be applied to the component.
The following fields are supported:

- **expanded**: Indicates whether the button, or another grouping element it controls, is currently expanded or collapsed.
Accepts the following string values: `true` or `false`

- **hasPopup**: Indicates the availability and type of interactive popup element, such as menu or dialog, that can be triggered by the button.
Accepts the following string values: `dialog`, `grid`, `listbox`, `menu` or `tree`.

- **ariaLabel**: Defines the accessible ARIA name of the component.
Accepts any string value.

 - **ariaKeyShortcuts**: Defines keyboard shortcuts that activate or give focus to the button.

- **controls**: Identifies the element (or elements) whose contents or presence are controlled by the button element.
Accepts a lowercase string value.
        */
  accessibilityAttributes!: ButtonAccessibilityAttributes;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines whether the button has special form-related functionality.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  type!: 'Button' | 'Submit' | 'Reset';
  /**
        Describes the accessibility role of the button.

**Note:** Use <code>ButtonAccessibleRole.Link</code> role only with a press handler, which performs a navigation. In all other scenarios the default button semantics are recommended.
        */
  accessibleRole!: 'Button' | 'Link';
  /**
        Defines whether the button shows a loading indicator.

**Note:** If set to `true`, a busy indicator component will be displayed on the related button.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Specifies the delay in milliseconds before the loading indicator appears within the associated button.
        */
  loadingDelay!: number;
  /**
        Determines whether the component is displayed as pressed.
        */
  @InputDecorator({ transform: booleanAttribute })
  pressed!: boolean;

  /**
     Fired when the component is activated either with a mouse/tap or by using the Enter or Space key.

**Note:** The event will not be fired if the `disabled` property is set to `true`.
    */
  ui5Click!: EventEmitter<ButtonClickEventDetail>;

  private elementRef: ElementRef<ToggleButton> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToggleButton {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToggleButtonComponent };
