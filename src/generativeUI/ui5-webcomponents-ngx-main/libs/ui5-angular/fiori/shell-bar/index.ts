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
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import {
  default as ShellBar,
  ShellBarAccessibilityAttributes,
  ShellBarContentItemVisibilityChangeEventDetail,
  ShellBarLogoClickEventDetail,
  ShellBarMenuItemClickEventDetail,
  ShellBarNotificationsClickEventDetail,
  ShellBarProductSwitchClickEventDetail,
  ShellBarProfileClickEventDetail,
  ShellBarSearchButtonEventDetail,
  ShellBarSearchFieldClearEventDetail,
  ShellBarSearchFieldToggleEventDetail,
} from '@ui5/webcomponents-fiori/dist/ShellBar.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'hideSearchButton',
  'disableSearchCollapse',
  'primaryTitle',
  'secondaryTitle',
  'notificationsCount',
  'showNotifications',
  'showProductSwitch',
  'showSearchField',
  'accessibilityAttributes',
])
@ProxyOutputs([
  'notifications-click: ui5NotificationsClick',
  'profile-click: ui5ProfileClick',
  'product-switch-click: ui5ProductSwitchClick',
  'logo-click: ui5LogoClick',
  'menu-item-click: ui5MenuItemClick',
  'search-button-click: ui5SearchButtonClick',
  'search-field-toggle: ui5SearchFieldToggle',
  'search-field-clear: ui5SearchFieldClear',
  'content-item-visibility-change: ui5ContentItemVisibilityChange',
])
@Component({
  standalone: true,
  selector: 'ui5-shellbar',
  template: '<ng-content></ng-content>',
  inputs: [
    'hideSearchButton',
    'disableSearchCollapse',
    'primaryTitle',
    'secondaryTitle',
    'notificationsCount',
    'showNotifications',
    'showProductSwitch',
    'showSearchField',
    'accessibilityAttributes',
  ],
  outputs: [
    'ui5NotificationsClick',
    'ui5ProfileClick',
    'ui5ProductSwitchClick',
    'ui5LogoClick',
    'ui5MenuItemClick',
    'ui5SearchButtonClick',
    'ui5SearchFieldToggle',
    'ui5SearchFieldClear',
    'ui5ContentItemVisibilityChange',
  ],
  exportAs: 'ui5Shellbar',
})
class ShellBarComponent {
  /**
        Defines the visibility state of the search button.

**Note:** The `hideSearchButton` property is in an experimental state and is a subject to change.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideSearchButton!: boolean;
  /**
        Disables the automatic search field expansion/collapse when the available space is not enough.

**Note:** The `disableSearchCollapse` property is in an experimental state and is a subject to change.
        */
  @InputDecorator({ transform: booleanAttribute })
  disableSearchCollapse!: boolean;
  /**
        Defines the `primaryTitle`.

**Note:** The `primaryTitle` would be hidden on S screen size (less than approx. 700px).
        */
  primaryTitle!: string | undefined;
  /**
        Defines the `secondaryTitle`.

**Note:** The `secondaryTitle` would be hidden on S and M screen sizes (less than approx. 1300px).
        */
  secondaryTitle!: string | undefined;
  /**
        Defines the `notificationsCount`,
displayed in the notification icon top-right corner.
        */
  notificationsCount!: string | undefined;
  /**
        Defines, if the notification icon would be displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  showNotifications!: boolean;
  /**
        Defines, if the product switch icon would be displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  showProductSwitch!: boolean;
  /**
        Defines, if the Search Field would be displayed when there is a valid `searchField` slot.

**Note:** By default the Search Field is not displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  showSearchField!: boolean;
  /**
        Defines additional accessibility attributes on different areas of the component.

The accessibilityAttributes object has the following fields,
where each field is an object supporting one or more accessibility attributes:

- **logo** - `logo.role` and `logo.name`.
- **notifications** - `notifications.expanded` and `notifications.hasPopup`.
- **profile** - `profile.expanded`, `profile.hasPopup` and `profile.name`.
- **product** - `product.expanded` and `product.hasPopup`.
- **search** - `search.hasPopup`.
- **overflow** - `overflow.expanded` and `overflow.hasPopup`.
- **branding** - `branding.name`.

The accessibility attributes support the following values:

- **role**: Defines the accessible ARIA role of the logo area.
Accepts the following string values: `button` or `link`.

- **expanded**: Indicates whether the button, or another grouping element it controls,
is currently expanded or collapsed.
Accepts the following string values: `true` or `false`.

- **hasPopup**: Indicates the availability and type of interactive popup element,
such as menu or dialog, that can be triggered by the button.

Accepts the following string values: `dialog`, `grid`, `listbox`, `menu` or `tree`.
- **name**: Defines the accessible ARIA name of the area.
Accepts any string.
        */
  accessibilityAttributes!: ShellBarAccessibilityAttributes;

  /**
     Fired, when the notification icon is activated.
    */
  ui5NotificationsClick!: EventEmitter<ShellBarNotificationsClickEventDetail>;
  /**
     Fired, when the profile slot is present.
    */
  ui5ProfileClick!: EventEmitter<ShellBarProfileClickEventDetail>;
  /**
     Fired, when the product switch icon is activated.

**Note:** You can prevent closing of overflow popover by calling `event.preventDefault()`.
    */
  ui5ProductSwitchClick!: EventEmitter<ShellBarProductSwitchClickEventDetail>;
  /**
     Fired, when the logo is activated.
    */
  ui5LogoClick!: EventEmitter<ShellBarLogoClickEventDetail>;
  /**
     Fired, when a menu item is activated

**Note:** You can prevent closing of overflow popover by calling `event.preventDefault()`.
    */
  ui5MenuItemClick!: EventEmitter<ShellBarMenuItemClickEventDetail>;
  /**
     Fired, when the search button is activated.

**Note:** You can prevent expanding/collapsing of the search field by calling `event.preventDefault()`.
    */
  ui5SearchButtonClick!: EventEmitter<ShellBarSearchButtonEventDetail>;
  /**
     Fired, when the search field is expanded or collapsed.
    */
  ui5SearchFieldToggle!: EventEmitter<ShellBarSearchFieldToggleEventDetail>;
  /**
     Fired, when the search cancel button is activated.

**Note:** You can prevent the default behavior (clearing the search field value) by calling `event.preventDefault()`. The search will still be closed.
**Note:** The `search-field-clear` event is in an experimental state and is a subject to change.
    */
  ui5SearchFieldClear!: EventEmitter<ShellBarSearchFieldClearEventDetail>;
  /**
     Fired, when an item from the content slot is hidden or shown.
**Note:** The `content-item-visibility-change` event is in an experimental state and is a subject to change.
    */
  ui5ContentItemVisibilityChange!: EventEmitter<ShellBarContentItemVisibilityChangeEventDetail>;

  private elementRef: ElementRef<ShellBar> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ShellBar {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ShellBarComponent };
