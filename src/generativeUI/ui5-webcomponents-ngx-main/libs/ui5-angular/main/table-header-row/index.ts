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
import '@ui5/webcomponents/dist/TableHeaderRow.js';
import TableHeaderRow from '@ui5/webcomponents/dist/TableHeaderRow.js';
@ProxyInputs(['sticky'])
@Component({
  standalone: true,
  selector: 'ui5-table-header-row',
  template: '<ng-content></ng-content>',
  inputs: ['sticky'],
  exportAs: 'ui5TableHeaderRow',
})
class TableHeaderRowComponent {
  /**
        Sticks the `ui5-table-header-row` to the top of a table.

Note: If used in combination with overflowMode "Scroll", the table needs a defined height for the sticky header to work as expected.
        */
  @InputDecorator({ transform: booleanAttribute })
  sticky!: boolean;

  private elementRef: ElementRef<TableHeaderRow> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableHeaderRow {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableHeaderRowComponent };
