import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/UserMenuItemGroup.js';
import UserMenuItemGroup from '@ui5/webcomponents-fiori/dist/UserMenuItemGroup.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['checkMode'])
@Component({
  standalone: true,
  selector: 'ui5-user-menu-item-group',
  template: '<ng-content></ng-content>',
  inputs: ['checkMode'],
  exportAs: 'ui5UserMenuItemGroup',
})
class UserMenuItemGroupComponent {
  /**
        Defines the component's check mode.
        */
  checkMode!: 'None' | 'Single' | 'Multiple';

  private elementRef: ElementRef<UserMenuItemGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserMenuItemGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserMenuItemGroupComponent };
