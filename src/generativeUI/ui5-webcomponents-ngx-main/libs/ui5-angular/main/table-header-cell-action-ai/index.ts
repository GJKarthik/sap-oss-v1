import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableHeaderCellActionAI.js';
import TableHeaderCellActionAI from '@ui5/webcomponents/dist/TableHeaderCellActionAI.js';
import { TableHeaderCellActionClickEventDetail } from '@ui5/webcomponents/dist/TableHeaderCellActionBase.js';

@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-table-header-cell-action-ai',
  template: '<ng-content></ng-content>',
  outputs: ['ui5Click'],
  exportAs: 'ui5TableHeaderCellActionAi',
})
class TableHeaderCellActionAIComponent {
  /**
     Fired when a header cell action is clicked.
    */
  ui5Click!: EventEmitter<TableHeaderCellActionClickEventDetail>;

  private elementRef: ElementRef<TableHeaderCellActionAI> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableHeaderCellActionAI {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableHeaderCellActionAIComponent };
