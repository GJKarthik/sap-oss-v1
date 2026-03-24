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
import '@ui5/webcomponents-fiori/dist/SideNavigation.js';
import {
  default as SideNavigation,
  SideNavigationSelectionChangeEventDetail,
} from '@ui5/webcomponents-fiori/dist/SideNavigation.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['collapsed', 'accessibleName'])
@ProxyOutputs(['selection-change: ui5SelectionChange'])
@Component({
  standalone: true,
  selector: 'ui5-side-navigation',
  template: '<ng-content></ng-content>',
  inputs: ['collapsed', 'accessibleName'],
  outputs: ['ui5SelectionChange'],
  exportAs: 'ui5SideNavigation',
})
class SideNavigationComponent {
  /**
        Defines whether the `ui5-side-navigation` is expanded or collapsed.

**Note:** The collapsed mode is not supported on phones.
The `ui5-side-navigation` component is intended to be used within a `ui5-navigation-layout`
component to ensure proper responsive behavior. If you choose not to use the
`ui5-navigation-layout`, you will need to implement the appropriate responsive patterns yourself,
particularly for phones where the collapsed mode should not be used.
        */
  @InputDecorator({ transform: booleanAttribute })
  collapsed!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;

  /**
     Fired when the selection has changed via user interaction
    */
  ui5SelectionChange!: EventEmitter<SideNavigationSelectionChangeEventDetail>;

  private elementRef: ElementRef<SideNavigation> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SideNavigation {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SideNavigationComponent };
