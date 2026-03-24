import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableRow.js';
import TableRow from '@ui5/webcomponents/dist/TableRow.js';
@ProxyInputs(['rowKey', 'position', 'interactive', 'navigated', 'movable'])
@Component({
  standalone: true,
  selector: 'ui5-table-row',
  template: '<ng-content></ng-content>',
  inputs: ['rowKey', 'position', 'interactive', 'navigated', 'movable'],
  exportAs: 'ui5TableRow',
})
class TableRowComponent {
  /**
        Unique identifier of the row.

**Note:** For selection features to work properly, this property is mandatory, and its value must not contain spaces.
        */
  rowKey!: string | undefined;
  /**
        Defines the 0-based position of the row related to the total number of rows within the table when the `ui5-table-virtualizer` feature is used.
        */
  position!: number | undefined;
  /**
        Defines the interactive state of the row.
        */
  @InputDecorator({ transform: booleanAttribute })
  interactive!: boolean;
  /**
        Defines the navigated state of the row.
        */
  @InputDecorator({ transform: booleanAttribute })
  navigated!: boolean;
  /**
        Defines whether the row is movable.
        */
  @InputDecorator({ transform: booleanAttribute })
  movable!: boolean;

  private elementRef: ElementRef<TableRow> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableRow {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableRowComponent };
