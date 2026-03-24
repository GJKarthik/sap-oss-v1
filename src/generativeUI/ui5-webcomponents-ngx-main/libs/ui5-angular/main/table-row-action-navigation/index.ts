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
import '@ui5/webcomponents/dist/TableRowActionNavigation.js';
import TableRowActionNavigation from '@ui5/webcomponents/dist/TableRowActionNavigation.js';
@ProxyInputs(['invisible', 'interactive'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-table-row-action-navigation',
  template: '<ng-content></ng-content>',
  inputs: ['invisible', 'interactive'],
  outputs: ['ui5Click'],
  exportAs: 'ui5TableRowActionNavigation',
})
class TableRowActionNavigationComponent {
  /**
        Defines the visibility of the row action.

**Note:** Invisible row actions still take up space, allowing to hide the action while maintaining its position.
        */
  @InputDecorator({ transform: booleanAttribute })
  invisible!: boolean;
  /**
        Defines the interactive state of the navigation action.
        */
  @InputDecorator({ transform: booleanAttribute })
  interactive!: boolean;

  /**
     Fired when a row action is clicked.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<TableRowActionNavigation> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableRowActionNavigation {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableRowActionNavigationComponent };
