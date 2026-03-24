import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/FilterItem.js';
import FilterItem from '@ui5/webcomponents-fiori/dist/FilterItem.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'additionalText'])
@Component({
  standalone: true,
  selector: 'ui5-filter-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'additionalText'],
  exportAs: 'ui5FilterItem',
})
class FilterItemComponent {
  /**
        Defines the text of the filter item.
        */
  text!: string | undefined;
  /**
        Defines the additional text of the filter item.
This text is typically used to show the number of selected filter options within this category.
        */
  additionalText!: string | undefined;

  private elementRef: ElementRef<FilterItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): FilterItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FilterItemComponent };
