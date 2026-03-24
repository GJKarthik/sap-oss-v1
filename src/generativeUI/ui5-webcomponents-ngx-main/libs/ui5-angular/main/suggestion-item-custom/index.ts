import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/SuggestionItemCustom.js';
import SuggestionItemCustom from '@ui5/webcomponents/dist/SuggestionItemCustom.js';
@ProxyInputs(['text'])
@Component({
  standalone: true,
  selector: 'ui5-suggestion-item-custom',
  template: '<ng-content></ng-content>',
  inputs: ['text'],
  exportAs: 'ui5SuggestionItemCustom',
})
class SuggestionItemCustomComponent {
  /**
        Defines the text of the `ui5-suggestion-item-custom`.
**Note:** The text property is considered only for autocomplete.
        */
  text!: string | undefined;

  private elementRef: ElementRef<SuggestionItemCustom> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SuggestionItemCustom {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SuggestionItemCustomComponent };
