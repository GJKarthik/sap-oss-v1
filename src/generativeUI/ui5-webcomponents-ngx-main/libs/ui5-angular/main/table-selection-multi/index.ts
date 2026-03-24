import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableSelectionMulti.js';
import TableSelectionMulti from '@ui5/webcomponents/dist/TableSelectionMulti.js';
@ProxyInputs(['selected', 'behavior', 'headerSelector'])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-table-selection-multi',
  template: '<ng-content></ng-content>',
  inputs: ['selected', 'behavior', 'headerSelector'],
  outputs: ['ui5Change'],
  exportAs: 'ui5TableSelectionMulti',
})
class TableSelectionMultiComponent {
  /**
        Defines the `row-key` values of selected rows, with each value separated by a space.
        */
  selected!: string | undefined;
  /**
        Defines the selection behavior.
        */
  behavior!: 'RowSelector' | 'RowOnly';
  /**
        Defines the selector of the header row.
        */
  headerSelector!: 'SelectAll' | 'ClearAll';

  /**
     Fired when the selection is changed by user interaction.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<TableSelectionMulti> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableSelectionMulti {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableSelectionMultiComponent };
