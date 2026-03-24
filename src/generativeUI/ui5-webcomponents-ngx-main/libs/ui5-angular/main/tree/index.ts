import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Tree.js';
import {
  default as Tree,
  TreeItemClickEventDetail,
  TreeItemDeleteEventDetail,
  TreeItemMouseoutEventDetail,
  TreeItemMouseoverEventDetail,
  TreeItemToggleEventDetail,
  TreeMoveEventDetail,
  TreeSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/Tree.js';
@ProxyInputs([
  'selectionMode',
  'noDataText',
  'headerText',
  'footerText',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
])
@ProxyOutputs([
  'item-toggle: ui5ItemToggle',
  'item-mouseover: ui5ItemMouseover',
  'item-mouseout: ui5ItemMouseout',
  'item-click: ui5ItemClick',
  'item-delete: ui5ItemDelete',
  'selection-change: ui5SelectionChange',
  'move: ui5Move',
  'move-over: ui5MoveOver',
])
@Component({
  standalone: true,
  selector: 'ui5-tree',
  template: '<ng-content></ng-content>',
  inputs: [
    'selectionMode',
    'noDataText',
    'headerText',
    'footerText',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
  ],
  outputs: [
    'ui5ItemToggle',
    'ui5ItemMouseover',
    'ui5ItemMouseout',
    'ui5ItemClick',
    'ui5ItemDelete',
    'ui5SelectionChange',
    'ui5Move',
    'ui5MoveOver',
  ],
  exportAs: 'ui5Tree',
})
class TreeComponent {
  /**
        Defines the selection mode of the component. Since the tree uses a `ui5-list` to display its structure,
the tree modes are exactly the same as the list modes, and are all applicable.
        */
  selectionMode!:
    | 'None'
    | 'Single'
    | 'SingleStart'
    | 'SingleEnd'
    | 'SingleAuto'
    | 'Multiple'
    | 'Delete'
    | undefined;
  /**
        Defines the text that is displayed when the component contains no items.
        */
  noDataText!: string | undefined;
  /**
        Defines the component header text.

**Note:** If the `header` slot is set, this property is ignored.
        */
  headerText!: string | undefined;
  /**
        Defines the component footer text.
        */
  footerText!: string | undefined;
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
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
     Fired when a tree item is expanded or collapsed.

**Note:** You can call `preventDefault()` on the event object to suppress the event, if needed.
This may be handy for example if you want to dynamically load tree items upon the user expanding a node.
Even if you prevented the event's default behavior, you can always manually call `toggle()` on a tree item.
    */
  ui5ItemToggle!: EventEmitter<TreeItemToggleEventDetail>;
  /**
     Fired when the mouse cursor enters the tree item borders.
    */
  ui5ItemMouseover!: EventEmitter<TreeItemMouseoverEventDetail>;
  /**
     Fired when the mouse cursor leaves the tree item borders.
    */
  ui5ItemMouseout!: EventEmitter<TreeItemMouseoutEventDetail>;
  /**
     Fired when a tree item is activated.
    */
  ui5ItemClick!: EventEmitter<TreeItemClickEventDetail>;
  /**
     Fired when the Delete button of any tree item is pressed.

**Note:** A Delete button is displayed on each item,
when the component `selectionMode` property is set to `Delete`.
    */
  ui5ItemDelete!: EventEmitter<TreeItemDeleteEventDetail>;
  /**
     Fired when selection is changed by user interaction
in `Single`, `SingleStart`, `SingleEnd` and `Multiple` modes.
    */
  ui5SelectionChange!: EventEmitter<TreeSelectionChangeEventDetail>;
  /**
     Fired when a movable tree item is moved over a potential drop target during a drag-and-drop operation.

If the new position is valid, prevent the default action of the event using `preventDefault()`.
    */
  ui5Move!: EventEmitter<TreeMoveEventDetail>;
  /**
     Fired when a movable tree item is dropped onto a drop target.

**Note:** The `move` event is fired only if there was a preceding `move-over` event with prevented default action.
    */
  ui5MoveOver!: EventEmitter<TreeMoveEventDetail>;

  private elementRef: ElementRef<Tree> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Tree {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TreeComponent };
