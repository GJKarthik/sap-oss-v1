import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ComboBoxItem.js';
import ComboBoxItem from '@ui5/webcomponents/dist/ComboBoxItem.js';
@ProxyInputs(['text', 'additionalText'])
@Component({
  standalone: true,
  selector: 'ui5-cb-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'additionalText'],
  exportAs: 'ui5CbItem',
})
class ComboBoxItemComponent {
  /**
        Defines the text of the component.
        */
  text!: string | undefined;
  /**
        Defines the additional text of the component.
        */
  additionalText!: string | undefined;

  private elementRef: ElementRef<ComboBoxItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ComboBoxItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ComboBoxItemComponent };
