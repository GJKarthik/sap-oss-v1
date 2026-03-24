import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableVirtualizer.js';
import {
  RangeChangeEventDetail,
  default as TableVirtualizer,
} from '@ui5/webcomponents/dist/TableVirtualizer.js';
@ProxyInputs(['rowHeight', 'rowCount', 'extraRows'])
@ProxyOutputs(['range-change: ui5RangeChange'])
@Component({
  standalone: true,
  selector: 'ui5-table-virtualizer',
  template: '<ng-content></ng-content>',
  inputs: ['rowHeight', 'rowCount', 'extraRows'],
  outputs: ['ui5RangeChange'],
  exportAs: 'ui5TableVirtualizer',
})
class TableVirtualizerComponent {
  /**
        Defines the height of the rows in the table.

**Note:** For virtualization to work properly, this property is mandatory.
        */
  rowHeight!: number;
  /**
        Defines the total count of rows in the table.

**Note:** For virtualization to work properly, this property is mandatory.
        */
  rowCount!: number;
  /**
        Defines the count of extra rows to be rendered at the top and bottom of the table.

**Note:** This property is experimental and may be changed or deleted in the future.
        */
  extraRows!: number;

  /**
     Fired when the virtualizer is changed by user interaction e.g. on scrolling.
    */
  ui5RangeChange!: EventEmitter<RangeChangeEventDetail>;

  private elementRef: ElementRef<TableVirtualizer> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableVirtualizer {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableVirtualizerComponent };
