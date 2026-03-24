import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/ProductSwitch.js';
import ProductSwitch from '@ui5/webcomponents-fiori/dist/ProductSwitch.js';

@Component({
  standalone: true,
  selector: 'ui5-product-switch',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5ProductSwitch',
})
class ProductSwitchComponent {
  private elementRef: ElementRef<ProductSwitch> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ProductSwitch {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ProductSwitchComponent };
