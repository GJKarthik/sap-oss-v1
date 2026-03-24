import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/SearchScope.js';
import SearchScope from '@ui5/webcomponents-fiori/dist/SearchScope.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'value'])
@Component({
  standalone: true,
  selector: 'ui5-search-scope',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'value'],
  exportAs: 'ui5SearchScope',
})
class SearchScopeComponent {
  /**
        Defines the text of the component.
        */
  text!: string;
  /**
        Defines the value of the `ui5-search-scope`.
Used for selection in Search scopes.
        */
  value!: string | undefined;

  private elementRef: ElementRef<SearchScope> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SearchScope {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SearchScopeComponent };
