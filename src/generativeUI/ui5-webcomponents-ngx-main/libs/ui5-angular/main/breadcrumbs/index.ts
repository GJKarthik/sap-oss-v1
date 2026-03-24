import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Breadcrumbs.js';
import {
  default as Breadcrumbs,
  BreadcrumbsItemClickEventDetail,
} from '@ui5/webcomponents/dist/Breadcrumbs.js';
@ProxyInputs(['design', 'separators'])
@ProxyOutputs(['item-click: ui5ItemClick'])
@Component({
  standalone: true,
  selector: 'ui5-breadcrumbs',
  template: '<ng-content></ng-content>',
  inputs: ['design', 'separators'],
  outputs: ['ui5ItemClick'],
  exportAs: 'ui5Breadcrumbs',
})
class BreadcrumbsComponent {
  /**
        Defines the visual appearance of the last BreadcrumbsItem.

The Breadcrumbs supports two visual appearances for the last BreadcrumbsItem:
- "Standard" - displaying the last item as "current page" (bold and without separator)
- "NoCurrentPage" - displaying the last item as a regular BreadcrumbsItem, followed by separator
        */
  design!: 'Standard' | 'NoCurrentPage';
  /**
        Determines the visual style of the separator between the breadcrumb items.
        */
  separators!:
    | 'Slash'
    | 'BackSlash'
    | 'DoubleBackSlash'
    | 'DoubleGreaterThan'
    | 'DoubleSlash'
    | 'GreaterThan';

  /**
     Fires when a `BreadcrumbsItem` is clicked.

**Note:** You can prevent browser location change by calling `event.preventDefault()`.
    */
  ui5ItemClick!: EventEmitter<BreadcrumbsItemClickEventDetail>;

  private elementRef: ElementRef<Breadcrumbs> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Breadcrumbs {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { BreadcrumbsComponent };
