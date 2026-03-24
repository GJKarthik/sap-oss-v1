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
import '@ui5/webcomponents/dist/List.js';
import {
  default as List,
  ListAccessibilityAttributes,
  ListItemClickEventDetail,
  ListItemCloseEventDetail,
  ListItemDeleteEventDetail,
  ListItemToggleEventDetail,
  ListMoveEventDetail,
  ListSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/List.js';
@ProxyInputs([
  'headerText',
  'footerText',
  'indent',
  'selectionMode',
  'noDataText',
  'separators',
  'growing',
  'growingButtonText',
  'loading',
  'loadingDelay',
  'accessibleName',
  'accessibilityAttributes',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'accessibleRole',
])
@ProxyOutputs([
  'item-click: ui5ItemClick',
  'item-close: ui5ItemClose',
  'item-toggle: ui5ItemToggle',
  'item-delete: ui5ItemDelete',
  'selection-change: ui5SelectionChange',
  'load-more: ui5LoadMore',
  'move-over: ui5MoveOver',
  'move: ui5Move',
])
@Component({
  standalone: true,
  selector: 'ui5-list',
  template: '<ng-content></ng-content>',
  inputs: [
    'headerText',
    'footerText',
    'indent',
    'selectionMode',
    'noDataText',
    'separators',
    'growing',
    'growingButtonText',
    'loading',
    'loadingDelay',
    'accessibleName',
    'accessibilityAttributes',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'accessibleRole',
  ],
  outputs: [
    'ui5ItemClick',
    'ui5ItemClose',
    'ui5ItemToggle',
    'ui5ItemDelete',
    'ui5SelectionChange',
    'ui5LoadMore',
    'ui5MoveOver',
    'ui5Move',
  ],
  exportAs: 'ui5List',
})
class ListComponent {
  /**
        Defines the component header text.

**Note:** If `header` is set this property is ignored.
        */
  headerText!: string | undefined;
  /**
        Defines the footer text.
        */
  footerText!: string | undefined;
  /**
        Determines whether the component is indented.
        */
  @InputDecorator({ transform: booleanAttribute })
  indent!: boolean;
  /**
        Defines the selection mode of the component.
        */
  selectionMode!:
    | 'None'
    | 'Single'
    | 'SingleStart'
    | 'SingleEnd'
    | 'SingleAuto'
    | 'Multiple'
    | 'Delete';
  /**
        Defines the text that is displayed when the component contains no items.
        */
  noDataText!: string | undefined;
  /**
        Defines the item separator style that is used.
        */
  separators!: 'All' | 'Inner' | 'None';
  /**
        Defines whether the component will have growing capability either by pressing a `More` button,
or via user scroll. In both cases `load-more` event is fired.

**Restrictions:** `growing="Scroll"` is not supported for Internet Explorer,
on IE the component will fallback to `growing="Button"`.
        */
  growing!: 'Button' | 'Scroll' | 'None';
  /**
        Defines the text that will be displayed inside the growing button.

**Note:** If not specified a built-in text will be displayed.

**Note:** This property takes effect if the `growing` property is set to the `Button`.
        */
  growingButtonText!: string | undefined;
  /**
        Defines if the component would display a loading indicator over the list.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will show up for this component.
        */
  loadingDelay!: number;
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines additional accessibility attributes on different areas of the component.

The accessibilityAttributes object has the following field:

 - **growingButton**: `growingButton.name`, `growingButton.description`.

 The accessibility attributes support the following values:

- **name**: Defines the accessible ARIA name of the growing button.
Accepts any string.

- **description**: Defines the accessible ARIA description of the growing button.
Accepts any string.

 **Note:** The `accessibilityAttributes` property is in an experimental state and is a subject to change.
        */
  accessibilityAttributes!: ListAccessibilityAttributes;
  /**
        Defines the IDs of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines the IDs of the elements that describe the component.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Defines the accessible role of the component.
        */
  accessibleRole!: 'List' | 'Menu' | 'Tree' | 'ListBox';

  /**
     Fired when an item is activated, unless the item's `type` property
is set to `Inactive`.

**Note**: This event is not triggered by interactions with selection components such as the checkboxes and radio buttons,
associated with non-default `selectionMode` values, or if any other **interactive** component
(such as a button or input) within the list item is directly clicked.
    */
  ui5ItemClick!: EventEmitter<ListItemClickEventDetail>;
  /**
     Fired when the `Close` button of any item is clicked

**Note:** This event is only applicable to list items that can be closed (such as notification list items),
not to be confused with `item-delete`.
    */
  ui5ItemClose!: EventEmitter<ListItemCloseEventDetail>;
  /**
     Fired when the `Toggle` button of any item is clicked.

**Note:** This event is only applicable to list items that can be toggled (such as notification group list items).
    */
  ui5ItemToggle!: EventEmitter<ListItemToggleEventDetail>;
  /**
     Fired when the Delete button of any item is pressed.

**Note:** A Delete button is displayed on each item,
when the component `selectionMode` property is set to `Delete`.
    */
  ui5ItemDelete!: EventEmitter<ListItemDeleteEventDetail>;
  /**
     Fired when selection is changed by user interaction
in `Single`, `SingleStart`, `SingleEnd` and `Multiple` selection modes.
    */
  ui5SelectionChange!: EventEmitter<ListSelectionChangeEventDetail>;
  /**
     Fired when the user scrolls to the bottom of the list.

**Note:** The event is fired when the `growing='Scroll'` property is enabled.
    */
  ui5LoadMore!: EventEmitter<void>;
  /**
     Fired when a movable list item is moved over a potential drop target during a dragging operation.

If the new position is valid, prevent the default action of the event using `preventDefault()`.
    */
  ui5MoveOver!: EventEmitter<ListMoveEventDetail>;
  /**
     Fired when a movable list item is dropped onto a drop target.

**Note:** `move` event is fired only if there was a preceding `move-over` with prevented default action.
    */
  ui5Move!: EventEmitter<ListMoveEventDetail>;

  private elementRef: ElementRef<List> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): List {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ListComponent };
