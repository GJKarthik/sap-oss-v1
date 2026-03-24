import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/SearchMessageArea.js';
import SearchMessageArea from '@ui5/webcomponents-fiori/dist/SearchMessageArea.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'description'])
@Component({
  standalone: true,
  selector: 'ui5-search-message-area',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'description'],
  exportAs: 'ui5SearchMessageArea',
})
class SearchMessageAreaComponent {
  /**
        Defines the text to be displayed.
        */
  text!: string | undefined;
  /**
        Defines the description text to be displayed.
        */
  description!: string | undefined;

  private elementRef: ElementRef<SearchMessageArea> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SearchMessageArea {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SearchMessageAreaComponent };
