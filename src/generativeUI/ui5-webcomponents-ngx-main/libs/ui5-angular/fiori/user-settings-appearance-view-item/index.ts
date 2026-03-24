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
import '@ui5/webcomponents-fiori/dist/UserSettingsAppearanceViewItem.js';
import UserSettingsAppearanceViewItem from '@ui5/webcomponents-fiori/dist/UserSettingsAppearanceViewItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import { ListItemAccessibilityAttributes } from '@ui5/webcomponents/dist/ListItem.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'navigated',
  'tooltip',
  'highlight',
  'selected',
  'movable',
  'accessibleName',
  'itemKey',
  'text',
  'icon',
  'colorScheme',
])
@ProxyOutputs(['detail-click: ui5DetailClick'])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-appearance-view-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'navigated',
    'tooltip',
    'highlight',
    'selected',
    'movable',
    'accessibleName',
    'itemKey',
    'text',
    'icon',
    'colorScheme',
  ],
  outputs: ['ui5DetailClick'],
  exportAs: 'ui5UserSettingsAppearanceViewItem',
})
class UserSettingsAppearanceViewItemComponent {
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

- **ariaSetsize**: Defines the number of items in the current set  when not all items in the set are present in the DOM.
**Note:** The value is an integer reflecting the number of items in the complete set. If the size of the entire set is unknown, set `-1`.

	- **ariaPosinset**: Defines an element's number or position in the current set when not all items are present in the DOM.
	**Note:** The value is an integer greater than or equal to 1, and less than or equal to the size of the set when that size is known.
        */
  accessibilityAttributes!: ListItemAccessibilityAttributes;
  /**
        The navigated state of the list item.
If set to `true`, a navigation indicator is displayed at the end of the list item.
        */
  @InputDecorator({ transform: booleanAttribute })
  navigated!: boolean;
  /**
        Defines the text of the tooltip that would be displayed for the list item.
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
        Defines whether the item is movable.
        */
  @InputDecorator({ transform: booleanAttribute })
  movable!: boolean;
  /**
        Defines the text alternative of the component.

**Note**: If not provided a default text alternative will be set, if present.
        */
  accessibleName!: string | undefined;
  /**
        Defines the unique identifier of the item.
        */
  itemKey!: string;
  /**
        Defines the text label displayed for the appearance item.
        */
  text!: string;
  /**
        Defines the icon of the appearance item.
        */
  icon!: string;
  /**
        Defines the color scheme of the avatar.
        */
  colorScheme!: string;

  /**
     Fired when the user clicks on the detail button when type is `Detail`.
    */
  ui5DetailClick!: EventEmitter<void>;

  private elementRef: ElementRef<UserSettingsAppearanceViewItem> =
    inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsAppearanceViewItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsAppearanceViewItemComponent };
