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
import '@ui5/webcomponents/dist/MenuItem.js';
import {
  MenuBeforeCloseEventDetail,
  MenuBeforeOpenEventDetail,
  default as MenuItem,
  MenuItemAccessibilityAttributes,
} from '@ui5/webcomponents/dist/MenuItem.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'navigated',
  'tooltip',
  'highlight',
  'selected',
  'text',
  'additionalText',
  'icon',
  'disabled',
  'loading',
  'loadingDelay',
  'accessibleName',
  'checked',
])
@ProxyOutputs([
  'detail-click: ui5DetailClick',
  'before-open: ui5BeforeOpen',
  'open: ui5Open',
  'before-close: ui5BeforeClose',
  'close: ui5Close',
  'check: ui5Check',
])
@Component({
  standalone: true,
  selector: 'ui5-menu-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'navigated',
    'tooltip',
    'highlight',
    'selected',
    'text',
    'additionalText',
    'icon',
    'disabled',
    'loading',
    'loadingDelay',
    'accessibleName',
    'checked',
  ],
  outputs: [
    'ui5DetailClick',
    'ui5BeforeOpen',
    'ui5Open',
    'ui5BeforeClose',
    'ui5Close',
    'ui5Check',
  ],
  exportAs: 'ui5MenuItem',
})
class MenuItemComponent {
  /**
        Defines the visual indication and behavior of the list items.
Available options are `Active` (by default), `Inactive`, `Detail` and `Navigation`.

**Note:** When set to `Active` or `Navigation`, the item will provide visual response upon press and hover,
while with type `Inactive` and `Detail` - will not.
        */
  type!: 'Inactive' | 'Active' | 'Detail' | 'Navigation';
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The following fields are supported:

- **ariaKeyShortcuts**: Indicated the availability of a keyboard shortcuts defined for the menu item.

- **role**: Defines the role of the menu item. If not set, menu item will have default role="menuitem".
        */
  accessibilityAttributes!: MenuItemAccessibilityAttributes;
  /**
        The navigated state of the list item.
If set to `true`, a navigation indicator is displayed at the end of the list item.
        */
  @InputDecorator({ transform: booleanAttribute })
  navigated!: boolean;
  /**
        Defines the text of the tooltip for the menu item.
        */
  tooltip!: string | undefined;
  /**
        Defines the highlight state of the list items.
Available options are: `"None"` (by default), `"Positive"`, `"Critical"`, `"Information"` and `"Negative"`.
        */
  highlight!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines the text of the tree item.
        */
  text!: string | undefined;
  /**
        Defines the `additionalText`, displayed in the end of the menu item.

**Note:** The additional text will not be displayed if there are items added in `items` slot or there are
components added to `endContent` slot.

The priority of what will be displayed at the end of the menu item is as follows:
sub-menu arrow (if there are items added in `items` slot) -> components added in `endContent` -> text set to `additionalText`.
        */
  additionalText!: string | undefined;
  /**
        Defines the icon to be displayed as graphical element within the component.
The SAP-icons font provides numerous options.

**Example:**

See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines whether menu item is in disabled state.

**Note:** A disabled menu item is noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will be displayed inside the corresponding menu popover.

**Note:** If set to `true` a busy indicator component will be displayed into the related one to the current menu item sub-menu popover.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will be displayed inside the corresponding menu popover.
        */
  loadingDelay!: number;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines whether menu item is in checked state.

**Note:** checked state is only taken into account when menu item is added to menu item group
with `checkMode` other than `None`.

**Note:** A checked menu item has a checkmark displayed at its end.
        */
  @InputDecorator({ transform: booleanAttribute })
  checked!: boolean;

  /**
     Fired when the user clicks on the detail button when type is `Detail`.
    */
  ui5DetailClick!: EventEmitter<void>;
  /**
     Fired before the menu is opened. This event can be cancelled, which will prevent the menu from opening.

**Note:** Since 1.14.0 the event is also fired before a sub-menu opens.
    */
  ui5BeforeOpen!: EventEmitter<MenuBeforeOpenEventDetail>;
  /**
     Fired after the menu is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired before the menu is closed. This event can be cancelled, which will prevent the menu from closing.
    */
  ui5BeforeClose!: EventEmitter<MenuBeforeCloseEventDetail>;
  /**
     Fired after the menu is closed.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fired when an item is checked or unchecked.
    */
  ui5Check!: EventEmitter<void>;

  private elementRef: ElementRef<MenuItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MenuItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MenuItemComponent };
