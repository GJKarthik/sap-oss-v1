import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/SideNavigationGroup.js';
import SideNavigationGroup from '@ui5/webcomponents-fiori/dist/SideNavigationGroup.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'disabled', 'tooltip', 'expanded'])
@Component({
  standalone: true,
  selector: 'ui5-side-navigation-group',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'disabled', 'tooltip', 'expanded'],
  exportAs: 'ui5SideNavigationGroup',
})
class SideNavigationGroupComponent {
  /**
        Defines the text of the item.
        */
  text!: string | undefined;
  /**
        Defines whether the component is disabled.
A disabled component can't be pressed or
focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the tooltip of the component.

A tooltip attribute should be provided, in order to represent meaning/function,
when the component is collapsed ("icon only" design is visualized) or the item text is truncated.
        */
  tooltip!: string | undefined;
  /**
        Defines if the item is expanded
        */
  @InputDecorator({ transform: booleanAttribute })
  expanded!: boolean;

  private elementRef: ElementRef<SideNavigationGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SideNavigationGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SideNavigationGroupComponent };
