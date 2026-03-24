import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableSelection.js';
import TableSelection from '@ui5/webcomponents/dist/TableSelection.js';
@ProxyInputs(['mode', 'selected'])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-table-selection',
  template: '<ng-content></ng-content>',
  inputs: ['mode', 'selected'],
  outputs: ['ui5Change'],
  exportAs: 'ui5TableSelection',
})
class TableSelectionComponent {
  /**
        Defines the selection mode.
        */
  mode!: 'None' | 'Single' | 'Multiple';
  /**
        Defines the selected rows separated by a space.
        */
  selected!: string;

  /**
     Fired when the selection is changed by user interaction.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<TableSelection> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableSelection {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableSelectionComponent };
