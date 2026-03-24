import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableCell.js';
import TableCell from '@ui5/webcomponents/dist/TableCell.js';
@ProxyInputs(['horizontalAlign'])
@Component({
  standalone: true,
  selector: 'ui5-table-cell',
  template: '<ng-content></ng-content>',
  inputs: ['horizontalAlign'],
  exportAs: 'ui5TableCell',
})
class TableCellComponent {
  /**
        Determines the horizontal alignment of table cells.
        */
  horizontalAlign!: 'Left' | 'Start' | 'Right' | 'End' | 'Center' | undefined;

  private elementRef: ElementRef<TableCell> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableCell {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableCellComponent };
