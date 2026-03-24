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
import '@ui5/webcomponents/dist/Token.js';
import Token from '@ui5/webcomponents/dist/Token.js';
@ProxyInputs(['text', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-token',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected'],
  exportAs: 'ui5Token',
})
class TokenComponent {
  /**
        Defines the text of the token.
        */
  text!: string | undefined;
  /**
        Defines whether the component is selected or not.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<Token> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Token {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TokenComponent };
