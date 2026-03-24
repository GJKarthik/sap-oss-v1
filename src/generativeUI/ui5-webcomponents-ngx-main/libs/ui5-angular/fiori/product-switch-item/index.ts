import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/ProductSwitchItem.js';
import ProductSwitchItem from '@ui5/webcomponents-fiori/dist/ProductSwitchItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['titleText', 'subtitleText', 'icon', 'target', 'targetSrc'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-product-switch-item',
  template: '<ng-content></ng-content>',
  inputs: ['titleText', 'subtitleText', 'icon', 'target', 'targetSrc'],
  outputs: ['ui5Click'],
  exportAs: 'ui5ProductSwitchItem',
})
class ProductSwitchItemComponent {
  /**
        Defines the title of the component.
        */
  titleText!: string | undefined;
  /**
        Defines the subtitle of the component.
        */
  subtitleText!: string | undefined;
  /**
        Defines the icon to be displayed as a graphical element within the component.

Example:

`<ui5-product-switch-item icon="palette">`

See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines a target where the `targetSrc` content must be open.

Available options are:

- `_self`
- `_top`
- `_blank`
- `_parent`
- `_search`

**Note:** By default target will be open in the same frame as it was clicked.
        */
  target!: string | undefined;
  /**
        Defines the component target URI. Supports standard hyperlink behavior.
        */
  targetSrc!: string | undefined;

  /**
     Fired when the `ui5-product-switch-item` is activated either with a
click/tap or by using the Enter or Space key.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<ProductSwitchItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ProductSwitchItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ProductSwitchItemComponent };
