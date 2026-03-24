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
import '@ui5/webcomponents/dist/TableRowAction.js';
import TableRowAction from '@ui5/webcomponents/dist/TableRowAction.js';
@ProxyInputs(['invisible', 'icon', 'text'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-table-row-action',
  template: '<ng-content></ng-content>',
  inputs: ['invisible', 'icon', 'text'],
  outputs: ['ui5Click'],
  exportAs: 'ui5TableRowAction',
})
class TableRowActionComponent {
  /**
        Defines the visibility of the row action.

**Note:** Invisible row actions still take up space, allowing to hide the action while maintaining its position.
        */
  @InputDecorator({ transform: booleanAttribute })
  invisible!: boolean;
  /**
        Defines the icon of the row action.

**Note:** For row actions to work properly, this property is mandatory.

**Note:** SAP-icons font provides numerous built-in icons. To find all the available icons, see the
[Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string;
  /**
        Defines the text of the row action.

**Note:** For row actions to work properly, this property is mandatory.
        */
  text!: string;

  /**
     Fired when a row action is clicked.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<TableRowAction> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableRowAction {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableRowActionComponent };
