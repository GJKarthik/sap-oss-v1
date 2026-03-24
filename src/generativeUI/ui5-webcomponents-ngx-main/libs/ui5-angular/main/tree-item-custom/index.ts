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
import { ListItemAccessibilityAttributes } from '@ui5/webcomponents/dist/ListItem.js';
import '@ui5/webcomponents/dist/TreeItemCustom.js';
import TreeItemCustom from '@ui5/webcomponents/dist/TreeItemCustom.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'navigated',
  'tooltip',
  'highlight',
  'selected',
  'icon',
  'expanded',
  'movable',
  'indeterminate',
  'hasChildren',
  'additionalTextState',
  'accessibleName',
  'hideSelectionElement',
])
@ProxyOutputs(['detail-click: ui5DetailClick'])
@Component({
  standalone: true,
  selector: 'ui5-tree-item-custom',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'navigated',
    'tooltip',
    'highlight',
    'selected',
    'icon',
    'expanded',
    'movable',
    'indeterminate',
    'hasChildren',
    'additionalTextState',
    'accessibleName',
    'hideSelectionElement',
  ],
  outputs: ['ui5DetailClick'],
  exportAs: 'ui5TreeItemCustom',
})
class TreeItemCustomComponent {
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
        If set, an icon will be displayed before the text of the tree list item.
        */
  icon!: string | undefined;
  /**
        Defines whether the tree list item will show a collapse or expand icon inside its toggle button.
        */
  @InputDecorator({ transform: booleanAttribute })
  expanded!: boolean;
  /**
        Defines whether the item is movable.
        */
  @InputDecorator({ transform: booleanAttribute })
  movable!: boolean;
  /**
        Defines whether the selection of a tree node is displayed as partially selected.

**Note:** The indeterminate state can be set only programmatically and can’t be achieved by user
interaction, meaning that the resulting visual state depends on the values of the `indeterminate`
and `selected` properties:

-  If a tree node has both `selected` and `indeterminate` set to `true`, it is displayed as partially selected.
-  If a tree node has `selected` set to `true` and `indeterminate` set to `false`, it is displayed as selected.
-  If a tree node has `selected` set to `false`, it is displayed as not selected regardless of the value of the `indeterminate` property.

**Note:** This property takes effect only when the `ui5-tree` is in `Multiple` mode.
        */
  @InputDecorator({ transform: booleanAttribute })
  indeterminate!: boolean;
  /**
        Defines whether the tree node has children, even if currently no other tree nodes are slotted inside.

**Note:** This property is useful for showing big tree structures where not all nodes are initially loaded due to performance reasons.
Set this to `true` for nodes you intend to load lazily, when the user clicks the expand button.
It is not necessary to set this property otherwise. If a tree item has children, the expand button will be displayed anyway.
        */
  @InputDecorator({ transform: booleanAttribute })
  hasChildren!: boolean;
  /**
        Defines the state of the `additionalText`.

Available options are: `"None"` (by default), `"Positive"`, `"Critical"`, `"Information"` and `"Negative"`.
        */
  additionalTextState!:
    | 'None'
    | 'Positive'
    | 'Critical'
    | 'Negative'
    | 'Information';
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines whether the tree list item should display the selection element.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideSelectionElement!: boolean;

  /**
     Fired when the user clicks on the detail button when type is `Detail`.
    */
  ui5DetailClick!: EventEmitter<void>;

  private elementRef: ElementRef<TreeItemCustom> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TreeItemCustom {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TreeItemCustomComponent };
