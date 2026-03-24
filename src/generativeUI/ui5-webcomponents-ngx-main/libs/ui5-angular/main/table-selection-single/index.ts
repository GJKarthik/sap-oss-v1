import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableSelectionSingle.js';
import TableSelectionSingle from '@ui5/webcomponents/dist/TableSelectionSingle.js';
@ProxyInputs(['selected', 'behavior'])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-table-selection-single',
  template: '<ng-content></ng-content>',
  inputs: ['selected', 'behavior'],
  outputs: ['ui5Change'],
  exportAs: 'ui5TableSelectionSingle',
})
class TableSelectionSingleComponent {
  /**
        Defines the `row-key` value of the selected row.
        */
  selected!: string | undefined;
  /**
        Defines the selection behavior.
        */
  behavior!: 'RowSelector' | 'RowOnly';

  /**
     Fired when the selection is changed by user interaction.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<TableSelectionSingle> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableSelectionSingle {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableSelectionSingleComponent };
