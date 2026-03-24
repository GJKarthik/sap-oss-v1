import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/FilterItemOption.js';
import FilterItemOption from '@ui5/webcomponents-fiori/dist/FilterItemOption.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-filter-item-option',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected'],
  exportAs: 'ui5FilterItemOption',
})
class FilterItemOptionComponent {
  /**
        Defines the text of the filter option.
        */
  text!: string | undefined;
  /**
        Defines if the filter option is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<FilterItemOption> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): FilterItemOption {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FilterItemOptionComponent };
