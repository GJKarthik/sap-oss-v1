import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/MultiComboBoxItem.js';
import MultiComboBoxItem from '@ui5/webcomponents/dist/MultiComboBoxItem.js';
@ProxyInputs(['text', 'additionalText', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-mcb-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'additionalText', 'selected'],
  exportAs: 'ui5McbItem',
})
class MultiComboBoxItemComponent {
  /**
        Defines the text of the component.
        */
  text!: string | undefined;
  /**
        Defines the additional text of the component.
        */
  additionalText!: string | undefined;
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<MultiComboBoxItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MultiComboBoxItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MultiComboBoxItemComponent };
