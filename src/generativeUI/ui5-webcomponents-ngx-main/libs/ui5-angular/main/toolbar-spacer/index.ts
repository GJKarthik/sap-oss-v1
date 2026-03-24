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
import '@ui5/webcomponents/dist/ToolbarSpacer.js';
import ToolbarSpacer from '@ui5/webcomponents/dist/ToolbarSpacer.js';
@ProxyInputs(['overflowPriority', 'preventOverflowClosing', 'width'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar-spacer',
  template: '<ng-content></ng-content>',
  inputs: ['overflowPriority', 'preventOverflowClosing', 'width'],
  exportAs: 'ui5ToolbarSpacer',
})
class ToolbarSpacerComponent {
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
  /**
        Defines the width of the spacer.

**Note:** all CSS sizes are supported - 'percentage', 'px', 'rem', 'auto', etc.
        */
  width!: string | undefined;

  private elementRef: ElementRef<ToolbarSpacer> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToolbarSpacer {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarSpacerComponent };
