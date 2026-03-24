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
import '@ui5/webcomponents/dist/ListItemStandard.js';
import ListItemStandard from '@ui5/webcomponents/dist/ListItemStandard.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'navigated',
  'tooltip',
  'highlight',
  'selected',
  'text',
  'description',
  'icon',
  'iconEnd',
  'additionalText',
  'additionalTextState',
  'movable',
  'accessibleName',
  'wrappingType',
])
@ProxyOutputs(['detail-click: ui5DetailClick'])
@Component({
  standalone: true,
  selector: 'ui5-li',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'navigated',
    'tooltip',
    'highlight',
    'selected',
    'text',
    'description',
    'icon',
    'iconEnd',
    'additionalText',
    'additionalTextState',
    'movable',
    'accessibleName',
    'wrappingType',
  ],
  outputs: ['ui5DetailClick'],
  exportAs: 'ui5Li',
})
class ListItemStandardComponent {
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
        Defines the text of the component.
        */
  text!: string | undefined;
  /**
        Defines the description displayed right under the item text, if such is present.
        */
  description!: string | undefined;
  /**
        Defines the `icon` source URI.

**Note:**
SAP-icons font provides numerous built-in icons. To find all the available icons, see the
[Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines whether the `icon` should be displayed in the beginning of the list item or in the end.
        */
  @InputDecorator({ transform: booleanAttribute })
  iconEnd!: boolean;
  /**
        Defines the `additionalText`, displayed in the end of the list item.
        */
  additionalText!: string | undefined;
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
        Defines whether the item is movable.
        */
  @InputDecorator({ transform: booleanAttribute })
  movable!: boolean;
  /**
        Defines the text alternative of the component.
Note: If not provided a default text alternative will be set, if present.
        */
  accessibleName!: string | undefined;
  /**
        Defines if the text of the component should wrap when it's too long.
When set to "Normal", the content (title, description) will be wrapped
using the `ui5-expandable-text` component.<br/>

The text can wrap up to 100 characters on small screens (size S) and
up to 300 characters on larger screens (size M and above). When text exceeds
these limits, it truncates with an ellipsis followed by a text expansion trigger.

Available options are:
- `None` (default) - The text will truncate with an ellipsis.
- `Normal` - The text will wrap (without truncation).
        */
  wrappingType!: 'None' | 'Normal';

  /**
     Fired when the user clicks on the detail button when type is `Detail`.
    */
  ui5DetailClick!: EventEmitter<void>;

  private elementRef: ElementRef<ListItemStandard> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ListItemStandard {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ListItemStandardComponent };
