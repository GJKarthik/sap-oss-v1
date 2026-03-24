import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/SortItem.js';
import SortItem from '@ui5/webcomponents-fiori/dist/SortItem.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-sort-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected'],
  exportAs: 'ui5SortItem',
})
class SortItemComponent {
  /**
        Defines the text of the sort item.
        */
  text!: string | undefined;
  /**
        Defines if the sort item is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<SortItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SortItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SortItemComponent };
