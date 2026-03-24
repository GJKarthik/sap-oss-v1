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
import '@ui5/webcomponents/dist/Table.js';
import {
  default as Table,
  TableMoveEventDetail,
  TableRowActionClickEventDetail,
  TableRowClickEventDetail,
} from '@ui5/webcomponents/dist/Table.js';
@ProxyInputs([
  'accessibleName',
  'accessibleNameRef',
  'noDataText',
  'overflowMode',
  'loading',
  'loadingDelay',
  'rowActionCount',
  'alternateRowColors',
])
@ProxyOutputs([
  'row-click: ui5RowClick',
  'move-over: ui5MoveOver',
  'move: ui5Move',
  'row-action-click: ui5RowActionClick',
])
@Component({
  standalone: true,
  selector: 'ui5-table',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleName',
    'accessibleNameRef',
    'noDataText',
    'overflowMode',
    'loading',
    'loadingDelay',
    'rowActionCount',
    'alternateRowColors',
  ],
  outputs: ['ui5RowClick', 'ui5MoveOver', 'ui5Move', 'ui5RowActionClick'],
  exportAs: 'ui5Table',
})
class TableComponent {
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Identifies the element (or elements) that labels the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the text to be displayed when there are no rows in the component.
        */
  noDataText!: string | undefined;
  /**
        Defines the mode of the <code>ui5-table</code> overflow behavior.

Available options are:

<code>Scroll</code> - Columns are shown as regular columns and horizontal scrolling is enabled.
<code>Popin</code> - Columns are shown as pop-ins instead of regular columns.
        */
  overflowMode!: 'Scroll' | 'Popin';
  /**
        Defines if the loading indicator should be shown.

**Note:** When the component is loading, it is not interactive.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will show up for this component.
        */
  loadingDelay!: number;
  /**
        Defines the maximum number of row actions that is displayed, which determines the width of the row action column.

**Note:** It is recommended to use a maximum of 3 row actions, as exceeding this limit may take up too much space on smaller screens.
        */
  rowActionCount!: number;
  /**
        Determines whether the table rows are displayed with alternating background colors.
        */
  @InputDecorator({ transform: booleanAttribute })
  alternateRowColors!: boolean;

  /**
     Fired when an interactive row is clicked.

**Note:** This event is not fired if the `behavior` property of the selection component is set to `RowOnly`.
In that case, use the `change` event of the selection component instead.
    */
  ui5RowClick!: EventEmitter<TableRowClickEventDetail>;
  /**
     Fired when a movable item is moved over a potential drop target during a dragging operation.

If the new position is valid, prevent the default action of the event using `preventDefault()`.

**Note:** If the dragging operation is a cross-browser operation or files are moved to a potential drop target,
the `source` parameter will be `null`.
    */
  ui5MoveOver!: EventEmitter<TableMoveEventDetail>;
  /**
     Fired when a movable list item is dropped onto a drop target.

**Notes:**

The `move` event is fired only if there was a preceding `move-over` with prevented default action.

If the dragging operation is a cross-browser operation or files are moved to a potential drop target,
the `source` parameter will be `null`.
    */
  ui5Move!: EventEmitter<TableMoveEventDetail>;
  /**
     Fired when a row action is clicked.
    */
  ui5RowActionClick!: EventEmitter<TableRowActionClickEventDetail>;

  private elementRef: ElementRef<Table> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Table {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableComponent };
