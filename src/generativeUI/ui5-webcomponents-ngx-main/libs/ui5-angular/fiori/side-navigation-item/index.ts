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
import '@ui5/webcomponents-fiori/dist/SideNavigationItem.js';
import SideNavigationItem from '@ui5/webcomponents-fiori/dist/SideNavigationItem.js';
import { SideNavigationItemClickEventDetail } from '@ui5/webcomponents-fiori/dist/SideNavigationItemBase.js';
import { SideNavigationItemAccessibilityAttributes } from '@ui5/webcomponents-fiori/dist/SideNavigationSelectableItemBase.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'text',
  'disabled',
  'tooltip',
  'icon',
  'selected',
  'href',
  'target',
  'design',
  'unselectable',
  'accessibilityAttributes',
  'expanded',
])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-side-navigation-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'text',
    'disabled',
    'tooltip',
    'icon',
    'selected',
    'href',
    'target',
    'design',
    'unselectable',
    'accessibilityAttributes',
    'expanded',
  ],
  outputs: ['ui5Click'],
  exportAs: 'ui5SideNavigationItem',
})
class SideNavigationItemComponent {
  /**
        Defines the text of the item.
        */
  text!: string | undefined;
  /**
        Defines whether the component is disabled.
A disabled component can't be pressed or
focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the tooltip of the component.

A tooltip attribute should be provided, in order to represent meaning/function,
when the component is collapsed ("icon only" design is visualized) or the item text is truncated.
        */
  tooltip!: string | undefined;
  /**
        Defines the icon of the item.

The SAP-icons font provides numerous options.

See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines whether the item is selected.

**Note:** Items that have a set `href` and `target` set to `_blank` should not be selectable.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines the link target URI. Supports standard hyperlink behavior.
If a JavaScript action should be triggered,
this should not be set, but instead an event handler
for the `click` event should be registered.
        */
  href!: string | undefined;
  /**
        Defines the component target.

Possible values:

- `_self`
- `_top`
- `_blank`
- `_parent`
- `framename`

**Note:** Items that have a defined `href` and `target`
attribute set to `_blank` should not be selectable.
        */
  target!: string | undefined;
  /**
        Item design.

**Note:** Items with "Action" design must not have sub-items.
        */
  design!: 'Default' | 'Action';
  /**
        Indicates whether the navigation item is selectable. By default, all items are selectable unless specifically marked as unselectable.

When a parent item is marked as unselectable, selecting it will only expand or collapse its sub-items.
To improve user experience do not mix unselectable parent items with selectable parent items in a single side navigation.


**Guidelines**:
- Items with an assigned `href` and a target of `_blank` should be marked as unselectable.
- Items that trigger actions (with design "Action") should be marked as unselectable.
        */
  @InputDecorator({ transform: booleanAttribute })
  unselectable!: boolean;
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The following fields are supported:

- **hasPopup**: Indicates the availability and type of interactive popup element, such as menu or dialog, that can be triggered by the button.
Accepts the following string values: `dialog`, `grid`, `listbox`, `menu` or `tree`.

**Note:** Do not use it on parent items, as it will be overridden if the item is in the overflow menu.
        */
  accessibilityAttributes!: SideNavigationItemAccessibilityAttributes;
  /**
        Defines if the item is expanded
        */
  @InputDecorator({ transform: booleanAttribute })
  expanded!: boolean;

  /**
     Fired when the component is activated either with a click/tap or by using the [Enter] or [Space] keys.
    */
  ui5Click!: EventEmitter<SideNavigationItemClickEventDetail>;

  private elementRef: ElementRef<SideNavigationItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SideNavigationItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SideNavigationItemComponent };
