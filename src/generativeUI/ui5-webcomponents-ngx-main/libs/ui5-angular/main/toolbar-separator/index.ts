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
import '@ui5/webcomponents/dist/ToolbarSeparator.js';
import ToolbarSeparator from '@ui5/webcomponents/dist/ToolbarSeparator.js';
@ProxyInputs(['overflowPriority', 'preventOverflowClosing'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar-separator',
  template: '<ng-content></ng-content>',
  inputs: ['overflowPriority', 'preventOverflowClosing'],
  exportAs: 'ui5ToolbarSeparator',
})
class ToolbarSeparatorComponent {
  /**
        Property used to define the access of the item to the overflow Popover. If "NeverOverflow" option is set,
the item never goes in the Popover, if "AlwaysOverflow" - it never comes out of it.
        */
  overflowPriority!: 'Default' | 'NeverOverflow' | 'AlwaysOverflow';
  /**
        Defines if the toolbar overflow popup should close upon intereaction with the item.
It will close by default.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventOverflowClosing!: boolean;

  private elementRef: ElementRef<ToolbarSeparator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToolbarSeparator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarSeparatorComponent };
