import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/BreadcrumbsItem.js';
import BreadcrumbsItem from '@ui5/webcomponents/dist/BreadcrumbsItem.js';
@ProxyInputs(['href', 'target', 'accessibleName'])
@Component({
  standalone: true,
  selector: 'ui5-breadcrumbs-item',
  template: '<ng-content></ng-content>',
  inputs: ['href', 'target', 'accessibleName'],
  exportAs: 'ui5BreadcrumbsItem',
})
class BreadcrumbsItemComponent {
  /**
        Defines the link href.

**Note:** Standard hyperlink behavior is supported.
        */
  href!: string | undefined;
  /**
        Defines the link target.

Available options are:

- `_self`
- `_top`
- `_blank`
- `_parent`
- `_search`

**Note:** This property must only be used when the `href` property is set.
        */
  target!: string | undefined;
  /**
        Defines the accessible ARIA name of the item.
        */
  accessibleName!: string | undefined;

  private elementRef: ElementRef<BreadcrumbsItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): BreadcrumbsItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { BreadcrumbsItemComponent };
