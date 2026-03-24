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
import '@ui5/webcomponents/dist/ToolbarButton.js';
import {
  default as ToolbarButton,
  ToolbarButtonAccessibilityAttributes,
} from '@ui5/webcomponents/dist/ToolbarButton.js';
@ProxyInputs([
  'overflowPriority',
  'preventOverflowClosing',
  'disabled',
  'design',
  'icon',
  'endIcon',
  'tooltip',
  'accessibleName',
  'accessibleNameRef',
  'accessibilityAttributes',
  'text',
  'showOverflowText',
  'width',
])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'overflowPriority',
    'preventOverflowClosing',
    'disabled',
    'design',
    'icon',
    'endIcon',
    'tooltip',
    'accessibleName',
    'accessibleNameRef',
    'accessibilityAttributes',
    'text',
    'showOverflowText',
    'width',
  ],
  outputs: ['ui5Click'],
  exportAs: 'ui5ToolbarButton',
})
class ToolbarButtonComponent {
  /**
        Property used to define the access of the item to the overflow Popover. If "NeverOverflow" option is set,
the item never goes in the Popover, if "AlwaysOverflow" - it never comes out of it.
        */
  overflowPriority!: 'Default' | 'NeverOverflow' | 'AlwaysOverflow';
  /**
        Defines if the toolbar overflow popup should close upon intereaction with the item.
It will close by default.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventOverflowClosing!: boolean;
  /**
        Defines if the action is disabled.

**Note:** a disabled action can't be pressed or focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the action design.
        */
  design!:
    | 'Default'
    | 'Positive'
    | 'Negative'
    | 'Transparent'
    | 'Emphasized'
    | 'Attention';
  /**
        Defines the `icon` source URI.

**Note:** SAP-icons font provides numerous buil-in icons. To find all the available icons, see the
[Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
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

- **controls**: Identifies the element (or elements) whose contents or presence are controlled by the button element.
Accepts a lowercase string value.
        */
  accessibilityAttributes!: ToolbarButtonAccessibilityAttributes;
  /**
        Button text
        */
  text!: string | undefined;
  /**
        Defines whether the button text should only be displayed in the overflow popover.

When set to `true`, the button appears as icon-only in the main toolbar,
but shows both icon and text when moved to the overflow popover.

**Note:** This property only takes effect when the `text` property is also set.
        */
  @InputDecorator({ transform: booleanAttribute })
  showOverflowText!: boolean;
  /**
        Defines the width of the button.

**Note:** all CSS sizes are supported - 'percentage', 'px', 'rem', 'auto', etc.
        */
  width!: string | undefined;

  /**
     Fired when the component is activated either with a
mouse/tap or by using the Enter or Space key.

**Note:** The event will not be fired if the `disabled`
property is set to `true`.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<ToolbarButton> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToolbarButton {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarButtonComponent };
