import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableGrowing.js';
import TableGrowing from '@ui5/webcomponents/dist/TableGrowing.js';
@ProxyInputs(['mode', 'text', 'subtext'])
@ProxyOutputs(['load-more: ui5LoadMore'])
@Component({
  standalone: true,
  selector: 'ui5-table-growing',
  template: '<ng-content></ng-content>',
  inputs: ['mode', 'text', 'subtext'],
  outputs: ['ui5LoadMore'],
  exportAs: 'ui5TableGrowing',
})
class TableGrowingComponent {
  /**
        Defines the mode of the <code>ui5-table</code> growing.

Available options are:

Button - Shows a More button at the bottom of the table, pressing it will load more rows.

Scroll - The rows are loaded automatically by scrolling to the bottom of the table. If the table is not scrollable,
a growing button will be rendered instead to ensure growing functionality.
        */
  mode!: 'Button' | 'Scroll';
  /**
        Defines the text that will be displayed inside the growing button.
Has no effect when mode is set to `Scroll`.

**Note:** When not provided and the mode is set to Button, a default text is displayed, corresponding to the
current language.
        */
  text!: string | undefined;
  /**
        Defines the text that will be displayed below the `text` inside the growing button.
Has no effect when mode is set to Scroll.
        */
  subtext!: string | undefined;

  /**
     Fired when the growing button is pressed or the user scrolls to the end of the table.
    */
  ui5LoadMore!: EventEmitter<void>;

  private elementRef: ElementRef<TableGrowing> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableGrowing {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableGrowingComponent };
