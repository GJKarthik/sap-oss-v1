import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/SuggestionItem.js';
import SuggestionItem from '@ui5/webcomponents/dist/SuggestionItem.js';
@ProxyInputs(['text', 'additionalText'])
@Component({
  standalone: true,
  selector: 'ui5-suggestion-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'additionalText'],
  exportAs: 'ui5SuggestionItem',
})
class SuggestionItemComponent {
  /**
        Defines the text of the component.
        */
  text!: string | undefined;
  /**
        Defines the `additionalText`, displayed in the end of the item.
        */
  additionalText!: string | undefined;

  private elementRef: ElementRef<SuggestionItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SuggestionItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SuggestionItemComponent };
