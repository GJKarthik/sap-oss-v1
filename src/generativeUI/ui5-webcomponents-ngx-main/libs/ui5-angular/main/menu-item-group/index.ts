import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/MenuItemGroup.js';
import MenuItemGroup from '@ui5/webcomponents/dist/MenuItemGroup.js';
@ProxyInputs(['checkMode'])
@Component({
  standalone: true,
  selector: 'ui5-menu-item-group',
  template: '<ng-content></ng-content>',
  inputs: ['checkMode'],
  exportAs: 'ui5MenuItemGroup',
})
class MenuItemGroupComponent {
  /**
        Defines the component's check mode.
        */
  checkMode!: 'None' | 'Single' | 'Multiple';

  private elementRef: ElementRef<MenuItemGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MenuItemGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MenuItemGroupComponent };
